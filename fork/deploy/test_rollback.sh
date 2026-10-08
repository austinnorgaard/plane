#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# test_rollback.sh - exercises rollback.sh against stub ssh, pct and docker
# commands that record their calls, and a fake app directory. Needs only bash
# and coreutils.
# Checks: exact command sequence per mode (dry-run and real), sed-check failure
# stops with no further steps, idempotence, secret hygiene, usage errors.
# --self-mutate: runs the suite against deliberately broken copies of
# rollback.sh and requires every mutant to be caught.
# shellcheck disable=SC2015,SC2016
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${ROLLBACK:-$HERE/rollback.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAIL=0
N=0
ok() { N=$((N + 1)); echo "ok   $1"; }
bad() { N=$((N + 1)); echo "FAIL $1"; FAIL=$((FAIL + 1)); }
check() { # check <name> <command...>: ok when the command succeeds
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

if [ "${1:-}" = --self-mutate ]; then
  M=$T/mut
  mkdir -p "$M"
  survived=0
  mutate() { # mutate <name> <sed-expr>
    sed -e "$2" "$HERE/rollback.sh" >"$M/rollback.sh"
    chmod +x "$M/rollback.sh"
    if cmp -s "$HERE/rollback.sh" "$M/rollback.sh"; then echo "MUTANT $1: sed did not change the file"; survived=1; return; fi
    if ROLLBACK=$M/rollback.sh "$HERE/test_rollback.sh" >/dev/null 2>&1; then
      echo "MUTANT $1: SURVIVED (tests still pass)"; survived=1
    else
      echo "MUTANT $1: killed"
    fi
  }
  mutate "no-sed-check" 's/^if \[ "\$off" = 5 \] && \[ "\$on" = 5 \] && \[ "\$left" = 0 \]; then$/if true; then/'
  # Dropping the "left" test is an equivalent mutant: left lines are a subset of the "on" lines, so
  # off=5 and on=5 already imply left=0. The RUNBOOK keeps it as a belt-and-braces check.
  mutate "check-ignores-on" 's/ && \[ "\$on" = 5 \]//'
  mutate "dry-run-executes" 's/^  if \[ "\$DRY" = 1 \]; then$/  if false; then/'
  mutate "forward-keeps-l1-file" 's/^rm -f docker-compose.override.l1.yaml$/true/'
  mutate "l2-pulls" 's/ --pull never//'
  mutate "l1-wrong-services" 's/up -d api worker live$/up -d/'
  mutate "step-failure-ignored" 's/^    echo "RESULT: \$MODE failed in step.*$/    echo ignored/'
  mutate "no-stock-image-check" 's/^if \[ -n "\$ids" \]; then$/if true; then/'
  mutate "forward-no-image-check" 's/^      if \[ -n "\$bad" \]; then$/      if false; then/'
  exit "$survived"
fi

mkdir -p "$T/bin" "$T/app"
cat >"$T/bin/ssh" <<'EOF'
#!/bin/sh
# stub ssh: log the call, drop "-o X" options and the host, run the command locally
echo "ssh $*" >>"$STUB_LOG"
while [ "$1" = -o ]; do shift 2; done
shift
[ -n "${STUB_SSH_RC:-}" ] && exit "$STUB_SSH_RC"
exec sh -c "$1"
EOF
cat >"$T/bin/pct" <<'EOF'
#!/bin/sh
echo "pct $*" >>"$STUB_LOG"
case "$1" in exec) shift 3; exec "$@" ;; esac
EOF
cat >"$T/bin/docker" <<'EOF'
#!/bin/sh
echo "DOCKER[$(basename "$PWD")][APP_RELEASE=${APP_RELEASE:-}] $*" >>"$STUB_LOG"
case "$1" in
  image) [ -n "${STUB_NO_STOCK:-}" ] || echo "abc123" ;;
  compose)
    case "$*" in
      *" ps "*)
        if [ -n "${STUB_PS_STOCK:-}" ]; then
          printf 'web makeplane/plane-frontend:v1.4.2\nlive makeplane/plane-live:v1.4.2\n'
        elif [ -n "${STUB_PS_BAD:-}" ]; then
          printf 'web localhost/plane-fork-web:v1.4.2-live.7\nlive makeplane/plane-live:v1.4.2\napi localhost/plane-fork-api:v1.4.2-live.7\nworker localhost/plane-fork-api:v1.4.2-live.7\nbeat-worker localhost/plane-fork-api:v1.4.2-live.7\n'
        else
          printf 'web localhost/plane-fork-web:v1.4.2-live.7\nlive localhost/plane-fork-live:v1.4.2-live.7\napi localhost/plane-fork-api:v1.4.2-live.7\nworker localhost/plane-fork-api:v1.4.2-live.7\nbeat-worker localhost/plane-fork-api:v1.4.2-live.7\nplane-db postgres:15\n'
        fi ;;
      *" up "*) echo "stub: up done" ;;
    esac ;;
esac
exit "${STUB_DOCKER_RC:-0}"
EOF
chmod +x "$T/bin/ssh" "$T/bin/pct" "$T/bin/docker"
export STUB_LOG="$T/log" PATH="$T/bin:$PATH"
export PVE_HOST=pve.example.test PLANE_CTID=999 PLANE_APP_DIR="$T/app/plane-app" STOCK_RELEASE=v1.4.2 FORK_N=7
SENTINEL="SENTINEL-not-a-real-secret-4711"
export LIVE_SERVER_SECRET_KEY=$SENTINEL
APP=$PLANE_APP_DIR

fresh_app() { # fresh_app [override-file]
  rm -rf "$APP"
  mkdir -p "$APP"
  cp "${1:-$HERE/docker-compose.override.yaml}" "$APP/docker-compose.override.yaml"
  printf 'services: {}\n' >"$APP/docker-compose.yaml"
  printf 'LIVE_SERVER_SECRET_KEY=%s\nFORK_N=7\n' "$SENTINEL" >"$APP/plane.env"
}
run() { : >"$STUB_LOG"; OUT=$("$SCRIPT" "$@" 2>&1); RC=$?; }
dockerlog() { grep '^DOCKER' "$STUB_LOG"; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

C1='compose -f docker-compose.yaml -f docker-compose.override.l1.yaml --env-file plane.env up -d api worker live'
C2='compose -f docker-compose.yaml --env-file plane.env up -d --pull never --wait --wait-timeout 60'
C2PS="compose -f docker-compose.yaml --env-file plane.env ps --format {{.Service}} {{.Image}}"
CF='compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env up -d'
CFPS="compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env ps --format {{.Service}} {{.Image}}"

echo "-- usage errors"
for args in "" "bogus" "l1 l2" "--dry-run" "l1 --bogus"; do
  # shellcheck disable=SC2086
  run $args
  { [ "$RC" = 1 ] && has usage && [ ! -s "$STUB_LOG" ]; } && ok "usage error rc=1, nothing run: '$args'" || bad "usage '$args' rc=$RC"
done
for v in PVE_HOST PLANE_CTID PLANE_APP_DIR; do
  (unset "$v"; run l1; [ "$RC" = 1 ] && has "set PVE_HOST" && [ ! -s "$STUB_LOG" ]) && ok "missing $v rejected" || bad "missing $v"
done
(PLANE_CTID=12x; run l1; [ "$RC" = 1 ] && [ ! -s "$STUB_LOG" ]) && ok "non-numeric CTID rejected" || bad "ctid"
(PLANE_APP_DIR=relative/dir; run l1; [ "$RC" = 1 ] && [ ! -s "$STUB_LOG" ]) && ok "relative app dir rejected" || bad "relative dir"
(PLANE_APP_DIR='/a b;rm'; run l1; [ "$RC" = 1 ] && [ ! -s "$STUB_LOG" ]) && ok "app dir with odd characters rejected" || bad "odd dir"
(PVE_HOST='-oProxyCommand=x'; run l1; [ "$RC" = 1 ] && [ ! -s "$STUB_LOG" ]) && ok "PVE_HOST starting with - rejected" || bad "host dash"
(STOCK_RELEASE=; run l2; [ "$RC" = 1 ] && has STOCK_RELEASE && [ ! -s "$STUB_LOG" ]) && ok "l2 needs STOCK_RELEASE" || bad "l2 stock"
(FORK_N=; run forward; [ "$RC" = 1 ] && has FORK_N && [ ! -s "$STUB_LOG" ]) && ok "forward needs FORK_N" || bad "forward n"
(FORK_N=7x; run forward; [ "$RC" = 1 ]) && ok "forward rejects non-numeric FORK_N" || bad "forward n numeric"
(STOCK_RELEASE=; fresh_app; run l1; [ "$RC" = 0 ]) && ok "l1 does not need STOCK_RELEASE" || bad "l1 stock not needed"

echo "-- dry-run changes nothing and runs nothing"
for m in l1 l2 forward; do
  fresh_app
  before=$(cd "$APP" && cksum ./* | sort)
  run --dry-run "$m"
  after=$(cd "$APP" && cksum ./* | sort)
  { [ "$RC" = 0 ] && [ ! -s "$STUB_LOG" ] && [ "$before" = "$after" ] && [ ! -e "$APP/docker-compose.override.l1.yaml" ]; } \
    && ok "$m dry-run: rc 0, no stub called, files untouched" || bad "$m dry-run rc=$RC"
  has "RESULT: dry-run only" && ok "$m dry-run says so" || bad "$m dry-run message"
  run "$m" --dry-run
  [ "$RC" = 0 ] && [ ! -s "$STUB_LOG" ] && ok "$m: flag order free" || bad "$m flag order"
done
run --dry-run l1
{ has "sed -e" && has "up -d api worker live" && has "ssh -o BatchMode=yes pve.example.test"; } && ok "l1 dry-run prints sed, up and the ssh line" || bad "l1 dry-run content"
run --dry-run l2
{ has "--pull never --wait --wait-timeout 60" && has "APP_RELEASE=\$STOCK_RELEASE"; } && ok "l2 dry-run prints the up line" || bad "l2 dry-run content"
run --dry-run forward
{ has "rm -f docker-compose.override.l1.yaml" && has "plane-fork-*:v1.4.2-live.7"; } && ok "forward dry-run prints rm and image check" || bad "forward dry-run content"

echo "-- l1 real"
fresh_app
ov_before=$(cksum <"$APP/docker-compose.override.yaml")
run l1
[ "$RC" = 0 ] && ok "l1 rc 0 on the real override" || bad "l1 rc=$RC: $OUT"
{ has "sed check ok" && has "RESULT: l1 done"; } && ok "l1 reports sed check ok" || bad "l1 report"
[ "$(dockerlog)" = "DOCKER[plane-app][APP_RELEASE=] $C1" ] && ok "l1 runs exactly one docker call: the L1 up" || bad "l1 docker sequence: $(dockerlog)"
[ "$(grep -c '^ssh' "$STUB_LOG")" = 2 ] && [ "$(grep -c '^pct exec 999 -- env APP_DIR=' "$STUB_LOG")" = 2 ] && ok "l1 goes ssh then pct exec, twice (generate, up)" || bad "l1 ssh/pct count"
[ "$(grep -c ': "0"$' "$APP/docker-compose.override.l1.yaml")" = 5 ] && ! grep -qE '(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): "1"' "$APP/docker-compose.override.l1.yaml" && ok "l1 file has 5 flags off, none on" || bad "l1 file content"
[ "$ov_before" = "$(cksum <"$APP/docker-compose.override.yaml")" ] && ok "override file untouched" || bad "override modified"
diff <(grep -vE '(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED)' "$APP/docker-compose.override.yaml") <(grep -vE '(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED)' "$APP/docker-compose.override.l1.yaml") >/dev/null && ok "only flag lines differ" || bad "other lines differ"
[ "$(printf '%s\n' "$OUT" | grep -c '^TIME ')" = 3 ] && has "TIME total:" && ok "l1 times both steps and the total" || bad "l1 timing"

echo "-- l1 idempotent"
sum1=$(cksum <"$APP/docker-compose.override.l1.yaml")
run l1
[ "$RC" = 0 ] && [ "$sum1" = "$(cksum <"$APP/docker-compose.override.l1.yaml")" ] && [ "$ov_before" = "$(cksum <"$APP/docker-compose.override.yaml")" ] && ok "second l1: rc 0, same L1 file, override unchanged" || bad "l1 twice"
[ "$(dockerlog)" = "DOCKER[plane-app][APP_RELEASE=] $C1" ] && ok "second l1 issues the same single up" || bad "l1 twice docker"

echo "-- sed check fails closed"
sedfail() { # sedfail <name> <sed-expr applied to the override>
  fresh_app
  sed -e "$2" "$HERE/docker-compose.override.yaml" >"$APP/docker-compose.override.yaml"
  run l1
  { [ "$RC" = 2 ] && has "STOP: expected exactly 5 flag lines" && ! dockerlog | grep -q . && [ "$(grep -c '^ssh' "$STUB_LOG")" = 1 ]; } \
    && ok "$1: rc 2, no docker call, no second step" || bad "$1: rc=$RC log=$(dockerlog)"
}
sedfail "flag line with a different format (4 matched)" '0,/LIVE_EVENTS_ENABLED: "1"/s//LIVE_EVENTS_ENABLED: 1/'
sedfail "an extra flag line left on" '$a\      PAGES_API_ENABLED: "1"'
sedfail "a sixth flag line the sed does not touch" '$a\      PAGES_API_ENABLED: "true"'
sedfail "a flag line missing" '0,/PAGES_API_ENABLED: "1"/{/PAGES_API_ENABLED: "1"/d}'
sedfail "a flag with another value" 's/^\( *\)PAGES_API_ENABLED: "1"$/\1PAGES_API_ENABLED: "true"/'
fresh_app
: >"$APP/docker-compose.override.yaml"
run l1
{ [ "$RC" = 2 ] && ! dockerlog | grep -q .; } && ok "empty override: rc 2, nothing started" || bad "empty override rc=$RC"
fresh_app
rm "$APP/docker-compose.override.yaml"
run l1
{ [ "$RC" = 2 ] && has "override.yaml not found" && ! dockerlog | grep -q .; } && ok "missing override: rc 2, nothing started" || bad "missing override rc=$RC"

echo "-- l1 up failure"
fresh_app
STUB_DOCKER_RC=1 run l1
{ [ "$RC" = 3 ] && has "failed in step"; } && ok "failing docker up gives rc 3" || bad "docker failure rc=$RC"
fresh_app
STUB_SSH_RC=255 run l1
{ [ "$RC" = 3 ] && ! dockerlog | grep -q . && [ "$(grep -c '^ssh' "$STUB_LOG")" = 1 ]; } && ok "ssh failure gives rc 3 and stops after the first step" || bad "ssh failure rc=$RC"

echo "-- l2 real"
fresh_app
run l2
[ "$RC" = 0 ] && ok "l2 rc 0" || bad "l2 rc=$RC: $OUT"
exp="DOCKER[plane-app][APP_RELEASE=] image ls -q makeplane/plane-backend:v1.4.2
DOCKER[plane-app][APP_RELEASE=v1.4.2] $C2
DOCKER[plane-app][APP_RELEASE=v1.4.2] $C2PS"
got=$(dockerlog)
[ "$got" = "$exp" ] && ok "l2 exact docker sequence (image check, up, ps)" || bad "l2 sequence: $got"
[ ! -e "$APP/docker-compose.override.l1.yaml" ] && ok "l2 does not create files" || bad "l2 created a file"
{ has "TIME up -d stock images" && has "hard-reload"; } && ok "l2 times the up and reminds about hard reload" || bad "l2 timing"
fresh_app
STUB_NO_STOCK=1 run l2
{ [ "$RC" = 2 ] && has "STOP: stock image" && ! dockerlog | grep -q ' up '; } && ok "l2 without the stock image: rc 2, no up" || bad "l2 no stock rc=$RC"
run l2
fresh_app
run l2; run l2
[ "$RC" = 0 ] && ok "l2 twice is safe" || bad "l2 twice"

echo "-- forward real"
fresh_app
run l1
run forward
[ "$RC" = 0 ] && ok "forward rc 0" || bad "forward rc=$RC: $OUT"
[ "$(dockerlog)" = "DOCKER[plane-app][APP_RELEASE=] $CF
DOCKER[plane-app][APP_RELEASE=] $CFPS" ] && ok "forward exact docker sequence (up, ps)" || bad "forward sequence: $(dockerlog)"
[ ! -e "$APP/docker-compose.override.l1.yaml" ] && ok "forward deletes the L1 file" || bad "L1 file still there"
[ -f "$APP/docker-compose.override.yaml" ] && ok "forward keeps the normal override" || bad "override gone"
has "image check ok" && ok "forward reports the image check" || bad "forward image check message"
run forward
[ "$RC" = 0 ] && ok "forward twice is safe (no L1 file)" || bad "forward twice rc=$RC"
fresh_app
run l1
STUB_PS_BAD=1 run forward
{ [ "$RC" = 2 ] && has "not on the fork tag" && has "live" && [ -e "$APP/docker-compose.override.l1.yaml" ]; } && ok "forward on stock images: rc 2, L1 file kept" || bad "forward stock rc=$RC"
STUB_PS_STOCK=1 run forward
[ "$RC" = 2 ] && ok "forward with services missing: rc 2" || bad "forward missing rc=$RC"
FORK_N=8 run forward
[ "$RC" = 2 ] && ok "forward with another FORK_N than running: rc 2" || bad "forward wrong N rc=$RC"

echo "-- secret hygiene"
fresh_app
: >"$T/all"
for m in l1 l2 forward; do
  run "$m"; printf '%s\n' "$OUT" >>"$T/all"
  run --dry-run "$m"; printf '%s\n' "$OUT" >>"$T/all"
  cat "$STUB_LOG" >>"$T/all"
done
grep -q "$SENTINEL" "$T/all" && bad "secret value leaked into output or argv" || ok "secret value absent from output, ssh/pct/docker argv"
grep -qE 'docker compose .* config|plane\.env *\||cat .*plane\.env|grep .*SECRET' "$T/all" && bad "script reads or prints env content" || ok "no compose config, no plane.env read"
grep -nE '(^|[^A-Za-z_])(config)( |$)' "$SCRIPT" | grep -v '^[0-9]*:#' | grep -q 'docker compose' && bad "script uses compose config" || ok "script never calls compose config"

echo "-- hygiene of the files"
check "no invisible unicode" bash -c "! grep -nP '[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{FEFF}\x{00AD}]' '$HERE/rollback.sh' '$HERE/test_rollback.sh'"
check "bash -n" bash -n "$SCRIPT"
check "--help exits 0" "$SCRIPT" --help

echo "== $N checks, $FAIL failed"
[ "$FAIL" = 0 ]
