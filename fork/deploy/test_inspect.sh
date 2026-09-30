#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# test_inspect.sh - exercises inspect.sh against stub `pct` and `docker`
# commands and a fake app directory. Needs only bash and coreutils.
# Checks: STOP exit codes, secret never printed nor placed in any argument
# list, nothing written into the app directory.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/app"
FAIL=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAIL=1; }

cat >"$T/bin/pct" <<'EOF'
#!/bin/sh
echo "pct $*" >>"$STUB_LOG"
case "$1" in
  status) echo "status: running" ;;
  listsnapshot) exit "${STUB_SNAP_RC:-0}" ;;
  exec) shift 3; exec "$@" ;;
esac
EOF
cat >"$T/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
svc=$(printf '%s\n' "$*" | sed -n 's/.*service=\([A-Za-z-]*\).*/\1/p')
case "$1" in
  ps)
    case "$*" in
      *"{{.Image}}"*) echo "localhost/plane-fork-$svc:v1.4.2-live.1" ;;
      *"{{.Ports}}"*) [ -n "${STUB_REDIS_PORTS:-}" ] && echo "$STUB_REDIS_PORTS" ;;
      *) echo "c_$svc" ;;
    esac ;;
  inspect) id=$(eval echo "\${$#}"); cat "$STUB_DIR/env.${id#c_}" 2>/dev/null ;;
esac
EOF
chmod +x "$T/bin/pct" "$T/bin/docker"
export STUB_LOG="$T/log" STUB_DIR="$T" PATH="$T/bin:$PATH"
export PLANE_CTID=999 PLANE_APP_DIR="$T/app"
SENTINEL=SENTINEL-not-a-real-secret-4711

cat >"$T/app/docker-compose.yaml" <<'EOF'
services:
  web:
    image: localhost/plane-fork-web:v1.4.2-live.1
  live:
    image: localhost/plane-fork-live:v1.4.2-live.1
  api:
    image: localhost/plane-fork-api:v1.4.2-live.1
  worker:
    image: localhost/plane-fork-api:v1.4.2-live.1
  beat-worker:
    image: localhost/plane-fork-api:v1.4.2-live.1
  plane-redis:
    image: valkey/valkey:7.2.11-alpine
EOF
setenv() { # setenv <secret-line-or-empty>
  { echo 'WEB_URL=https://plane.example.test'; [ -n "$1" ] && echo "$1"; } >"$T/app/plane.env"
}
for s in api worker beat-worker; do printf 'PATH=/bin\nA=b\n' >"$T/env.$s"; done
before=$(cksum <"$T/app/docker-compose.yaml")

run() { : >"$STUB_LOG"; OUT=$("$HERE/inspect.sh" "$@" 2>&1); RC=$?; }

setenv "LIVE_SERVER_SECRET_KEY=$SENTINEL"
run
[ "$RC" = 0 ] && ok "clean run exits 0" || bad "clean run rc=$RC"
echo "$OUT" | grep -q 'secret=no-match' && ok "no-match reported" || bad "no-match"
echo "$OUT" | grep -q 'WEB_URL=https://plane.example.test' && ok "WEB_URL printed" || bad "WEB_URL"
echo "$OUT" | grep -q 'image.live=localhost/plane-fork-live' && ok "image lines printed" || bad "image lines"
echo "$OUT" | grep -q 'listsnapshot: works' && ok "listsnapshot works" || bad "listsnapshot"
echo "$OUT" | grep -q 'plane-redis: no-published-ports' && ok "redis no ports" || bad "redis"
if echo "$OUT" | grep -q "$SENTINEL" || grep -q "$SENTINEL" "$STUB_LOG"; then bad "secret leaked"; else ok "secret absent from output and argv"; fi

setenv "LIVE_SERVER_SECRET_KEY=change-this-key-on-deployment"
run
[ "$RC" = 2 ] && echo "$OUT" | grep -q '^STOP: .*placeholder' && ok "placeholder -> STOP, exit 2" || bad "placeholder rc=$RC"
setenv "LIVE_SERVER_SECRET_KEY=\"change-this-key-on-deployment\""
run
[ "$RC" = 2 ] && ok "quoted placeholder -> STOP" || bad "quoted placeholder rc=$RC"
setenv "LIVE_SERVER_SECRET_KEY="
run
[ "$RC" = 2 ] && echo "$OUT" | grep -q '^STOP: .*empty' && ok "empty -> STOP" || bad "empty rc=$RC"
setenv ""
run
[ "$RC" = 2 ] && ok "unset -> STOP" || bad "unset rc=$RC"

setenv "LIVE_SERVER_SECRET_KEY=$SENTINEL"
printf 'LIVE_BASE_URL=http://live:3000\n' >"$T/env.worker"
run
[ "$RC" = 2 ] && echo "$OUT" | grep -q '^STOP: LIVE_BASE_URL is set on worker' && ok "worker LIVE_BASE_URL -> STOP" || bad "worker rc=$RC"
echo "$OUT" | grep -q 'http://live:3000' && bad "LIVE_BASE_URL value printed" || ok "LIVE_BASE_URL value not printed"
printf 'A=b\n' >"$T/env.worker"
printf 'LIVE_BASE_URL=http://live:3000\n' >"$T/env.beat-worker"
run
[ "$RC" = 2 ] && ok "beat-worker LIVE_BASE_URL -> STOP" || bad "beat-worker rc=$RC"
printf 'A=b\n' >"$T/env.beat-worker"
printf 'LIVE_BASE_URL=http://live:3000\n' >"$T/env.api"
run
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^api: set' && ok "api LIVE_BASE_URL is allowed" || bad "api rc=$RC"

STUB_REDIS_PORTS='0.0.0.0:6379->6379/tcp' run
echo "$OUT" | grep -q 'plane-redis: publishes-ports' && ok "redis ports detected" || bad "redis ports"
echo "$OUT" | grep -q '6379' && bad "port numbers printed" || ok "port numbers not printed"

run --dry-run
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'pct exec 999' && echo "$OUT" | grep -q 'pct listsnapshot 999' && ok "dry-run prints commands" || bad "dry-run rc=$RC"
[ ! -s "$STUB_LOG" ] && ok "dry-run executed nothing" || bad "dry-run executed something"
echo "$OUT" | grep -q "$SENTINEL" && bad "dry-run leaked" || ok "dry-run has no secret"

if grep -nE '(^|[^A-Za-z_-])(pkill|kill|pct (stop|start|shutdown|snapshot|rollback|set|push|destroy))([^A-Za-z_-]|$)|docker (rm|stop|restart|kill|exec|compose)' "$HERE/inspect.sh" | grep -v '^[0-9]*:#'; then
  bad "inspect.sh contains a mutating or kill command"
else ok "no mutating or kill commands in inspect.sh"; fi

[ "$(cksum <"$T/app/docker-compose.yaml")" = "$before" ] && ok "compose file untouched" || bad "compose changed"
[ "$(ls "$T/app" | sort | tr '\n' ' ')" = "docker-compose.yaml plane.env " ] && ok "no new files in app dir" || bad "app dir has new files"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
