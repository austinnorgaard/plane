#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# cloud-api-tests.sh - the Plane API pytest suite of api-tests.sh, run natively (no podman pod).
#
# It starts (or reuses) postgres, redis/valkey and rabbitmq on 127.0.0.1, creates or reuses a
# python venv, installs apps/api/requirements/test.txt, exports the same environment as
# api-tests.sh and runs pytest from apps/api.
#
# Usage:
#   fork/test/cloud-api-tests.sh                                   # plane/tests/unit plane/tests/contract, services from apt
#   fork/test/cloud-api-tests.sh --services docker                 # services in docker run containers
#   fork/test/cloud-api-tests.sh --services external               # services already running; only probe them
#   fork/test/cloud-api-tests.sh plane/tests/unit/utils -k slug    # any pytest args replace the default paths
#   fork/test/cloud-api-tests.sh --services apt -- -m unit         # "--" ends the script options
#
# Options (before the pytest args):
#   --services apt|docker|external   how to provide the services (default: $PLANE_TEST_SERVICES or apt)
#   --keep                           docker mode: leave the containers this run created running
#   -h, --help
#
# Service modes. In every mode a service that already answers on its port is reused and never
# started twice, so the script is safe to re-run.
#   apt       local packages: postgresql (pg_ctlcluster), redis-server, rabbitmq-server. Missing
#             packages are installed with apt-get when running as root. Started services are left
#             running afterwards.
#   docker    containers plane-cloudtest-{db,redis,mq}, published on 127.0.0.1 only. Containers
#             this run created are removed at exit unless --keep. Existing ones are reused.
#   external  nothing is started; the script fails if a service is unreachable.
#
# Environment overrides (defaults in brackets):
#   PLANE_SRC            tree under test [the repository this script lives in]
#   OUT_DIR              logs and junit output [${TMPDIR:-/tmp}/plane-cloud-tests]
#   PLANE_VENV           venv directory [${XDG_CACHE_HOME:-$HOME/.cache}/plane-cloud-tests/venv]
#   PYTHON               interpreter used to create the venv [python3.12, else python3]
#   DB_HOST DB_PORT DB_USER DB_PASS DB_NAME    [127.0.0.1 5432 plane plane plane]
#   REDIS_HOST REDIS_PORT                      [127.0.0.1 6379]
#   MQ_HOST MQ_PORT MQ_USER MQ_PASS MQ_VHOST   [127.0.0.1 5672 plane plane plane]
#   PG_IMAGE REDIS_IMAGE MQ_IMAGE              docker mode images (postgres 15.7 alpine, valkey 7.2.11, rabbitmq 3.13.6)
#   PLANE_TEST_SKIP_SETUP=1                    test seam: skip service start and venv setup, use PLANE_VENV as is
# apt and docker modes accept loopback hosts only (use --services external for anything else).
# The credentials are throwaway test values, never real secrets.
#
# Outputs in OUT_DIR: cloud-api-tests.pytest.log, .pip.log, .junit.xml, .summary.txt.
# Exit code: pytest's, or 2 for a setup problem.

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() { sed -n '/^# Usage:/,/^# Exit code/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# parse_args ARGS... -> sets SERVICES, KEEP, PYTEST_ARGS. Returns 2 on a bad option.
parse_args() {
  SERVICES=${PLANE_TEST_SERVICES:-apt}
  KEEP=0
  PYTEST_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --services)   [ "$#" -ge 2 ] || { echo "--services needs a value (apt|docker|external)" >&2; return 2; }
                    SERVICES=$2; shift 2 ;;
      --services=*) SERVICES=${1#--services=}; shift ;;
      --keep)       KEEP=1; shift ;;
      -h|--help)    usage; return 3 ;;
      --)           shift; PYTEST_ARGS+=("$@"); break ;;
      *)            PYTEST_ARGS+=("$@"); break ;;   # first non-option: the rest is for pytest
    esac
  done
  case "$SERVICES" in
    apt|docker|external) ;;
    *) echo "invalid --services value: $SERVICES (use apt, docker or external)" >&2; return 2 ;;
  esac
  if [ "${#PYTEST_ARGS[@]}" -eq 0 ]; then
    PYTEST_ARGS=(plane/tests/unit plane/tests/contract)
  fi
}

# Only run when executed, so the self test can source this file for parse_args.
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0 2>/dev/null || true; fi

set -uo pipefail

parse_args "$@"; prc=$?
if [ "$prc" -eq 3 ]; then exit 0; elif [ "$prc" -ne 0 ]; then exit 2; fi

SRC=${PLANE_SRC:-$(cd "$SELF_DIR/../.." && pwd)}
OUT_DIR=${OUT_DIR:-${TMPDIR:-/tmp}/plane-cloud-tests}
VENV=${PLANE_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/plane-cloud-tests/venv}

DB_HOST=${DB_HOST:-127.0.0.1} DB_PORT=${DB_PORT:-5432} DB_USER=${DB_USER:-plane} DB_PASS=${DB_PASS:-plane} DB_NAME=${DB_NAME:-plane}
REDIS_HOST=${REDIS_HOST:-127.0.0.1} REDIS_PORT=${REDIS_PORT:-6379}
MQ_HOST=${MQ_HOST:-127.0.0.1} MQ_PORT=${MQ_PORT:-5672} MQ_USER=${MQ_USER:-plane} MQ_PASS=${MQ_PASS:-plane} MQ_VHOST=${MQ_VHOST:-plane}
S3_KEY=access-key S3_SECRET=secret-key S3_BUCKET=uploads

PG_IMAGE=${PG_IMAGE:-docker.io/library/postgres:15.7-alpine}
REDIS_IMAGE=${REDIS_IMAGE:-docker.io/valkey/valkey:7.2.11-alpine}
MQ_IMAGE=${MQ_IMAGE:-docker.io/library/rabbitmq:3.13.6-management-alpine}
C_DB=plane-cloudtest-db C_REDIS=plane-cloudtest-redis C_MQ=plane-cloudtest-mq

[ -d "$SRC/apps/api/plane" ] || { echo "no apps/api under PLANE_SRC=$SRC" >&2; exit 2; }
mkdir -p "$OUT_DIR"

is_loopback() { case "$1" in 127.*|localhost|::1) return 0 ;; *) return 1 ;; esac; }

log() { echo "[cloud-api-tests $(date +%H:%M:%S)] $*"; }
die() { log "ERROR: $*"; exit 2; }

# apt and docker modes create throwaway services with throwaway credentials: only ever on loopback,
# and only with plain values, because the values reach SQL and rabbitmqctl arguments.
guard_config() {
  [ "$SERVICES" = external ] && return 0
  local v h
  for h in DB_HOST REDIS_HOST MQ_HOST; do
    is_loopback "${!h}" || die "--services $SERVICES only manages local throwaway services; $h=${!h} is not a loopback address (use --services external)"
  done
  if [ "$SERVICES" = apt ]; then
    for v in DB_USER DB_PASS DB_NAME MQ_USER MQ_PASS MQ_VHOST; do
      case "${!v}" in
        ''|*[!A-Za-z0-9_.@-]*) die "$v must be non-empty and use only letters, digits and _ . @ - in apt mode" ;;
      esac
    done
  fi
}
guard_config

CREATED=()
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  if [ "$SERVICES" = docker ] && [ "$KEEP" != 1 ] && [ "${#CREATED[@]}" -gt 0 ]; then
    docker rm -f "${CREATED[@]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---- probes (a service that answers is reused in every mode) ----
tcp_open() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; }
pg_up()    { tcp_open "$DB_HOST" "$DB_PORT"; }
redis_up() { tcp_open "$REDIS_HOST" "$REDIS_PORT"; }
mq_up()    { tcp_open "$MQ_HOST" "$MQ_PORT"; }

wait_for() { # name timeout_s command...
  local name=$1 timeout=$2 i=0; shift 2
  until "$@" >/dev/null 2>&1; do
    i=$((i + 2)); sleep 2
    [ "$i" -ge "$timeout" ] && { log "TIMEOUT waiting for $name"; return 1; }
  done
  log "$name ready (~${i}s)"
}

as_postgres() { if [ "$(id -u)" = 0 ]; then su postgres -c "$1"; else sudo -n -u postgres bash -c "$1"; fi; }

# ---- apt mode ----
apt_ensure_packages() {
  local pkgs=()
  command -v pg_lsclusters >/dev/null 2>&1 || pkgs+=(postgresql)
  command -v redis-server  >/dev/null 2>&1 || pkgs+=(redis-server)
  command -v rabbitmq-server >/dev/null 2>&1 || pkgs+=(rabbitmq-server)
  # psycopg-c has no wheel and compiles: it needs libpq headers and python headers
  command -v pg_config >/dev/null 2>&1 || pkgs+=(libpq-dev)
  if [ "${#pkgs[@]}" -gt 0 ]; then
    [ "$(id -u)" = 0 ] || die "missing packages (${pkgs[*]}); install them or run as root"
    log "apt-get install ${pkgs[*]}"
    apt-get update >/dev/null 2>&1 || true   # a broken third-party source only warns
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null || die "apt-get install failed"
  fi
}

apt_start_postgres() {
  if ! pg_up; then
    local ver name
    read -r ver name < <(pg_lsclusters --no-header | awk 'NR==1{print $1, $2}')
    [ -n "${ver:-}" ] || die "no postgres cluster found (pg_lsclusters is empty)"
    log "starting postgres cluster $ver/$name"
    pg_ctlcluster "$ver" "$name" start || die "pg_ctlcluster start failed"
  fi
  wait_for postgres 60 pg_up || die "postgres not reachable"
  # test runs create a test database, so the role must be a superuser
  as_postgres "psql -qtAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" | grep -q 1 \
    || { log "WARNING: creating throwaway SUPERUSER role '$DB_USER' in the local postgres cluster on port $DB_PORT"
         as_postgres "psql -qc \"CREATE ROLE $DB_USER LOGIN SUPERUSER PASSWORD '$DB_PASS'\"" || die "create role failed"; }
  as_postgres "psql -qtAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"" | grep -q 1 \
    || as_postgres "psql -qc 'CREATE DATABASE $DB_NAME OWNER $DB_USER'" || die "create database failed"
  # an existing role keeps its old password: fail here rather than in the middle of the tests
  PGPASSWORD=$DB_PASS psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -qtAc 'SELECT 1' >/dev/null 2>&1 \
    || die "postgres role '$DB_USER' cannot log in to '$DB_NAME' at $DB_HOST:$DB_PORT with the configured DB_PASS; set DB_USER/DB_PASS to a working login or reset the role password"
}

apt_start_redis() {
  if ! redis_up; then
    log "starting redis-server on port $REDIS_PORT"
    redis-server --port "$REDIS_PORT" --bind "$REDIS_HOST" --daemonize yes --save "" --appendonly no >/dev/null || die "redis-server failed"
  fi
  wait_for redis 30 redis_up || die "redis not reachable"
}

apt_start_rabbitmq() {
  if ! mq_up; then
    log "starting rabbitmq-server"
    rabbitmq-server -detached >/dev/null 2>&1 || die "rabbitmq-server failed"
  fi
  wait_for rabbitmq 120 mq_up || die "rabbitmq not reachable"
  rabbitmqctl await_startup >/dev/null 2>&1 || true
  rabbitmqctl list_vhosts -q 2>/dev/null | grep -qx "$MQ_VHOST" || rabbitmqctl add_vhost "$MQ_VHOST" >/dev/null || die "add_vhost failed"
  rabbitmqctl list_users -q 2>/dev/null | awk '{print $1}' | grep -qx "$MQ_USER" \
    || rabbitmqctl add_user "$MQ_USER" "$MQ_PASS" >/dev/null || die "add_user failed"
  rabbitmqctl authenticate_user "$MQ_USER" "$MQ_PASS" >/dev/null 2>&1 \
    || die "rabbitmq user '$MQ_USER' cannot authenticate with the configured MQ_PASS; set MQ_USER/MQ_PASS to a working login or reset the user password"
  rabbitmqctl set_permissions -p "$MQ_VHOST" "$MQ_USER" ".*" ".*" ".*" >/dev/null || die "set_permissions failed"
}

# ---- docker mode ----
# docker_run NAME PORT_SPEC IMAGE [docker options...] [-- command args...]
# Reuses a running container, starts a stopped one, else creates it.
docker_run() {
  local name=$1 port=$2 image=$3; shift 3
  local opts=() cmd=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  cmd=("$@")
  local state
  state=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo none)
  case "$state" in
    true)  log "container $name already running" ;;
    false) log "starting existing container $name"; docker start "$name" >/dev/null || die "docker start $name failed" ;;
    *)     log "creating container $name"
           docker run -d --name "$name" -p "127.0.0.1:$port" "${opts[@]}" "$image" "${cmd[@]}" >/dev/null || die "docker run $name failed"
           CREATED+=("$name") ;;
  esac
}

# docker_ready CONTAINER PROBE_FN cmd... : exec cmd in our container; if it is not ours (a service
# that was already running elsewhere), fall back to the TCP probe.
# shellcheck disable=SC2329  # invoked via wait_for
docker_ready() {
  local c=$1 probe=$2; shift 2
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]; then
    docker exec "$c" "$@"
  else
    "$probe"
  fi
}

docker_start_all() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
  pg_up || docker_run "$C_DB" "$DB_PORT:5432" "$PG_IMAGE" --tmpfs /var/lib/postgresql/data \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB="$DB_NAME" \
    -- postgres -c fsync=off -c synchronous_commit=off -c full_page_writes=off
  redis_up || docker_run "$C_REDIS" "$REDIS_PORT:6379" "$REDIS_IMAGE" --tmpfs /data
  mq_up || docker_run "$C_MQ" "$MQ_PORT:5672" "$MQ_IMAGE" --tmpfs /var/lib/rabbitmq \
    -e RABBITMQ_DEFAULT_USER="$MQ_USER" -e RABBITMQ_DEFAULT_PASS="$MQ_PASS" -e RABBITMQ_DEFAULT_VHOST="$MQ_VHOST"
}

start_services() {
  case "$SERVICES" in
    apt)
      apt_ensure_packages
      apt_start_postgres; apt_start_redis; apt_start_rabbitmq ;;
    docker)
      docker_start_all
      # a published docker port accepts connections before the server inside is ready, so ask the server
      wait_for postgres 90 docker_ready "$C_DB" pg_up pg_isready -U "$DB_USER" -d "$DB_NAME" || die "postgres not ready"
      wait_for redis 60 docker_ready "$C_REDIS" redis_up sh -c 'valkey-cli ping || redis-cli ping' || die "redis not ready"
      wait_for rabbitmq 180 docker_ready "$C_MQ" mq_up rabbitmq-diagnostics -q ping || die "rabbitmq not ready" ;;
    external)
      pg_up    || die "postgres not reachable at $DB_HOST:$DB_PORT"
      redis_up || die "redis not reachable at $REDIS_HOST:$REDIS_PORT"
      mq_up    || die "rabbitmq not reachable at $MQ_HOST:$MQ_PORT" ;;
  esac
  log "services ready (mode=$SERVICES): postgres :$DB_PORT, redis :$REDIS_PORT, rabbitmq :$MQ_PORT"
}

# ---- python venv ----
setup_venv() {
  local py=${PYTHON:-}
  if [ -z "$py" ]; then
    if command -v python3.12 >/dev/null 2>&1; then py=python3.12; else py=python3; fi
  fi
  command -v "$py" >/dev/null 2>&1 || die "python not found ($py)"
  if [ ! -x "$VENV/bin/python" ]; then
    log "creating venv $VENV with $py"
    mkdir -p "$(dirname "$VENV")"
    if command -v uv >/dev/null 2>&1; then uv venv --python "$py" "$VENV" >/dev/null || die "uv venv failed"
    else "$py" -m venv "$VENV" || die "python -m venv failed"; fi
  else
    log "reusing venv $VENV"
  fi
  local stamp="$VENV/.plane-requirements.sha256" want
  want=$(cat "$SRC"/apps/api/requirements/*.txt | sha256sum | cut -d' ' -f1)
  if [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
    log "requirements unchanged since the last install"
  else
    log "installing requirements/test.txt (log: $OUT_DIR/cloud-api-tests.pip.log)"
    if command -v uv >/dev/null 2>&1; then
      (cd "$SRC/apps/api" && uv pip install --python "$VENV/bin/python" -r requirements/test.txt) >"$OUT_DIR/cloud-api-tests.pip.log" 2>&1
    else
      (cd "$SRC/apps/api" && "$VENV/bin/python" -m pip install -r requirements/test.txt) >"$OUT_DIR/cloud-api-tests.pip.log" 2>&1
    fi || { tail -20 "$OUT_DIR/cloud-api-tests.pip.log"; die "requirements install failed"; }
    echo "$want" >"$stamp"
  fi
}

# Test seam (used by cloud-tests.selftest.sh): skip service start and the venv/pip step and use the
# venv given in PLANE_VENV as is.
if [ "${PLANE_TEST_SKIP_SETUP:-0}" = 1 ]; then
  [ -x "$VENV/bin/python" ] || die "PLANE_TEST_SKIP_SETUP=1 needs an existing venv in PLANE_VENV"
else
  start_services
  setup_venv
fi

export DJANGO_SETTINGS_MODULE=plane.settings.test SECRET_KEY=test-only-not-a-secret
export DATABASE_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME" POSTGRES_HOST=$DB_HOST
export REDIS_HOST REDIS_URL="redis://$REDIS_HOST:$REDIS_PORT/"
export RABBITMQ_HOST=$MQ_HOST RABBITMQ_USER=$MQ_USER RABBITMQ_PASSWORD=$MQ_PASS RABBITMQ_VHOST=$MQ_VHOST
export AWS_ACCESS_KEY_ID=$S3_KEY AWS_SECRET_ACCESS_KEY=$S3_SECRET AWS_S3_BUCKET_NAME=$S3_BUCKET
export AWS_S3_ENDPOINT_URL=http://127.0.0.1:9000
export WEB_URL=http://localhost:8000 EMAIL_HOST=test-smtp.invalid

cd "$SRC/apps/api" || exit 2
mkdir -p plane/static-assets/collected-static plane/logs
"$VENV/bin/python" -c "import pytest_mock" 2>/dev/null || die "pytest-mock is not importable in $VENV"

log "running pytest ${PYTEST_ARGS[*]} in $SRC/apps/api"
rm -f "$OUT_DIR/cloud-api-tests.junit.xml"
"$VENV/bin/python" -m pytest -p no:cacheprovider -rfEs --junitxml="$OUT_DIR/cloud-api-tests.junit.xml" "${PYTEST_ARGS[@]}" 2>&1 \
  | tee "$OUT_DIR/cloud-api-tests.pytest.log"
rc=${PIPESTATUS[0]}

{
  echo "CLOUDAPI services=$SERVICES pytest_rc=$rc"
  grep -aE '^=+ .*(passed|failed|error).* in [0-9.]+s' "$OUT_DIR/cloud-api-tests.pytest.log" | tail -1
  echo "--- FAILED / ERROR ids:"
  grep -aE '^(FAILED|ERROR) ' "$OUT_DIR/cloud-api-tests.pytest.log" | sort -u
} | tee "$OUT_DIR/cloud-api-tests.summary.txt"

exit "$rc"
