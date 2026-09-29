#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# live-smoke.sh [IMAGE] - boot a live image next to a throwaway valkey and GET /live/health.
#
# The live server exits at startup ("Redis client not initialized") without a
# Redis, so the smoke test runs it in a pod with a valkey sidecar. Nothing is
# published: the request is made from inside the live container.
#
# Usage (inside the WSL podman distro, as root):
#   live-smoke.sh localhost/plane-fork-live:spike
# Prints "HTTP 200 {...}" and exits 0 on success; exits 1 otherwise.
# Dummy values only: LIVE_SERVER_SECRET_KEY below is not a real secret.
set -uo pipefail

IMAGE=${1:-localhost/plane-fork-live:spike}
POD=lu-live-smoke
REDIS_IMAGE=docker.io/valkey/valkey:7.2.11-alpine

cleanup() { podman pod rm -f "$POD" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

podman pod create --name "$POD" >/dev/null || exit 1
podman run -d --pod "$POD" --name lu-smoke-redis --tmpfs /data "$REDIS_IMAGE" >/dev/null || exit 1
sleep 3
podman run -d --pod "$POD" --name lu-smoke-live \
  -e API_BASE_URL=http://127.0.0.1:9 \
  -e LIVE_SERVER_SECRET_KEY=dummy-not-a-secret \
  -e REDIS_URL=redis://127.0.0.1:6379 \
  "$IMAGE" >/dev/null || exit 1

# wait up to 30 s for the health endpoint
for _ in $(seq 1 15); do
  out=$(podman exec lu-smoke-live node -e "fetch('http://127.0.0.1:3000/live/health').then(async r=>{console.log('HTTP',r.status,await r.text());process.exit(r.status===200?0:1)}).catch(()=>process.exit(2))" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then echo "$out"; exit 0; fi
  sleep 2
done
echo "live-smoke FAILED (rc=$rc). Container log:" >&2
podman logs lu-smoke-live 2>&1 | tail -20 >&2
exit 1
