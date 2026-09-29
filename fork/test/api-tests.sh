#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# api-tests.sh - run the Plane API pytest suite in a throwaway podman pod.
#
# Layout (design section 7): pod "plane-apitest" holds postgres, valkey,
# rabbitmq and (optionally, see MINIO_IMAGE) minio, all on tmpfs, with NO published ports. The runner is the
# stock makeplane/plane-backend image joined to the same pod (so every service is
# on 127.0.0.1), with apps/api of the tree under test mounted at /code and
# requirements/test.txt installed on top of the image's own dependencies.
#
# Usage (inside the WSL podman distro, as root):
#   api-tests.sh                                  # plane/tests/unit plane/tests/contract
#   api-tests.sh plane/tests/unit/utils -k slug   # any pytest args replace the default paths
#   PLANE_SRC=/root/plane-build/spike api-tests.sh   # test a different tree
#   KEEP_POD=1 api-tests.sh                       # leave the pod up for debugging
#
# From Windows:  wsl.exe -d <distro> -u root -- /root/plane-work/fork/test/api-tests.sh
#
# Outputs (OUT_DIR, default /root/plane-build/logs):
#   api-tests.pytest.log   full pytest output
#   api-tests.pip.log      pip install output (check: no "Building wheel"/sdist compile)
#   api-tests.junit.xml    junit report
#   api-tests.summary.txt  pass/fail/skip counts and failing test ids
# Exit code is pytest's exit code, so a red baseline exits non-zero.
set -uo pipefail

SRC=${PLANE_SRC:-/root/plane-work}
OUT_DIR=${OUT_DIR:-/root/plane-build/logs}
BACKEND_IMAGE=${BACKEND_IMAGE:-docker.io/makeplane/plane-backend:v1.4.2}
POD=plane-apitest
PG_IMAGE=docker.io/library/postgres:15.7-alpine
REDIS_IMAGE=docker.io/valkey/valkey:7.2.11-alpine
MQ_IMAGE=docker.io/library/rabbitmq:3.13.6-management-alpine
# MinIO: upstream's compose files use docker.io/minio/minio, but MinIO has withdrawn its
# public images (docker.io and quay.io both answer "access denied" as of 2026-09-29,
# see SPIKE.md). The unit and contract suites mock S3, so the pod runs without it.
# Set MINIO_IMAGE=<any working minio image> to add it to the pod.
MINIO_IMAGE=${MINIO_IMAGE:-}

# Throwaway credentials, only ever valid inside this pod. Never real secrets.
DB_USER=plane DB_PASS=plane DB_NAME=plane
MQ_USER=plane MQ_PASS=plane MQ_VHOST=plane
S3_KEY=access-key S3_SECRET=secret-key S3_BUCKET=uploads

mkdir -p "$OUT_DIR"
[ -d "$SRC/apps/api/plane" ] || { echo "no apps/api under PLANE_SRC=$SRC" >&2; exit 2; }

log() { echo "[api-tests $(date +%H:%M:%S)] $*"; }

cleanup() {
  if [ "${KEEP_POD:-0}" != "1" ]; then
    podman pod rm -f "$POD" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

podman pod rm -f "$POD" >/dev/null 2>&1 || true
# No -p / --publish anywhere: services are reachable only from inside the pod.
podman pod create --name "$POD" >/dev/null || exit 2

log "starting postgres, valkey, rabbitmq${MINIO_IMAGE:+, minio} (tmpfs)"
podman run -d --pod "$POD" --name apitest-db \
  --tmpfs /var/lib/postgresql/data \
  -e POSTGRES_USER=$DB_USER -e POSTGRES_PASSWORD=$DB_PASS -e POSTGRES_DB=$DB_NAME \
  "$PG_IMAGE" postgres -c fsync=off -c synchronous_commit=off -c full_page_writes=off >/dev/null || exit 2
podman run -d --pod "$POD" --name apitest-redis --tmpfs /data "$REDIS_IMAGE" >/dev/null || exit 2
podman run -d --pod "$POD" --name apitest-mq \
  --tmpfs /var/lib/rabbitmq \
  -e RABBITMQ_DEFAULT_USER=$MQ_USER -e RABBITMQ_DEFAULT_PASS=$MQ_PASS -e RABBITMQ_DEFAULT_VHOST=$MQ_VHOST \
  "$MQ_IMAGE" >/dev/null || exit 2
if [ -n "$MINIO_IMAGE" ]; then
  podman run -d --pod "$POD" --name apitest-minio \
    --tmpfs /export \
    -e MINIO_ROOT_USER=$S3_KEY -e MINIO_ROOT_PASSWORD=$S3_SECRET \
    "$MINIO_IMAGE" server /export --console-address :9090 >/dev/null || exit 2
fi

wait_for() { # name, timeout_s, command...
  local name=$1 timeout=$2; shift 2
  local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 2)); sleep 2
    if [ "$i" -ge "$timeout" ]; then log "TIMEOUT waiting for $name"; return 1; fi
  done
  log "$name ready (~${i}s)"
}
wait_for postgres 90 podman exec apitest-db pg_isready -h 127.0.0.1 -U $DB_USER -d $DB_NAME || exit 2
wait_for valkey 60 podman exec apitest-redis valkey-cli ping || exit 2
wait_for rabbitmq 180 podman exec apitest-mq rabbitmq-diagnostics -q ping || exit 2
if [ -n "$MINIO_IMAGE" ]; then
  wait_for minio 60 podman run --rm --pod "$POD" "$BACKEND_IMAGE" python -c \
    "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9000/minio/health/ready').status==200 else 1)" || exit 2
fi

if [ "$#" -eq 0 ]; then
  set -- plane/tests/unit plane/tests/contract
fi

log "running pytest from $SRC/apps/api with image $BACKEND_IMAGE"
rm -f "$OUT_DIR"/api-tests.junit.xml
podman run --rm --pod "$POD" --name apitest-runner \
  -v "$SRC/apps/api:/code" -v "$OUT_DIR:/out" -w /code \
  -e DJANGO_SETTINGS_MODULE=plane.settings.test \
  -e SECRET_KEY=test-only-not-a-secret \
  -e DATABASE_URL="postgresql://$DB_USER:$DB_PASS@127.0.0.1:5432/$DB_NAME" \
  -e POSTGRES_HOST=127.0.0.1 \
  -e REDIS_HOST=127.0.0.1 -e REDIS_URL=redis://127.0.0.1:6379/ \
  -e RABBITMQ_HOST=127.0.0.1 -e RABBITMQ_USER=$MQ_USER -e RABBITMQ_PASSWORD=$MQ_PASS -e RABBITMQ_VHOST=$MQ_VHOST \
  -e AWS_ACCESS_KEY_ID=$S3_KEY -e AWS_SECRET_ACCESS_KEY=$S3_SECRET -e AWS_S3_BUCKET_NAME=$S3_BUCKET \
  -e AWS_S3_ENDPOINT_URL=http://127.0.0.1:9000 \
  -e WEB_URL=http://localhost:8000 \
  -e EMAIL_HOST=test-smtp.invalid \
  "$BACKEND_IMAGE" bash -c '
    set -e
    # Same install as docker-compose-test.yml, but logged so we can prove nothing compiles.
    pip install --no-cache-dir -r requirements/test.txt >/out/api-tests.pip.log 2>&1
    mkdir -p plane/static-assets/collected-static plane/logs
    # pytest-mock is what the pages tests use; fail early if it is not importable.
    python -c "import importlib.metadata as m, pytest_mock; print(\"pytest-mock\", m.version(\"pytest-mock\"), \"importable\")" | tee /out/api-tests.import.log
    set +e
    pytest -p no:cacheprovider -rfEs --junitxml=/out/api-tests.junit.xml "$@"
  ' -- "$@" 2>&1 | tee "$OUT_DIR/api-tests.pytest.log"
rc=${PIPESTATUS[0]}

{
  echo "pytest exit code: $rc"
  grep -E '^(=+ )?[0-9]+ (passed|failed)|^=+ .*(passed|failed|error).* in [0-9.]+s' "$OUT_DIR/api-tests.pytest.log" | tail -2
  echo "--- pip compile check (expect zero lines):"
  grep -Ec 'Building wheel|Running setup.py|Preparing metadata \(pyproject.toml\)' "$OUT_DIR/api-tests.pip.log"
  echo "--- FAILED / ERROR ids:"
  grep -E '^(FAILED|ERROR) ' "$OUT_DIR/api-tests.pytest.log" | sort -u
} | tee "$OUT_DIR/api-tests.summary.txt"

exit "$rc"
