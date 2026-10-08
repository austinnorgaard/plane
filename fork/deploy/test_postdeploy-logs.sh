#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# test_postdeploy-logs.sh - exercises postdeploy-logs.sh against stub ssh, pct
# and docker commands that emit canned logs. Needs only bash, GNU sed, awk and
# coreutils.
# Checks: usage and hostile-value refusal (no ssh call), dry-run, ssh timeout
# options, clean / over-threshold / traceback / 409 / live scenarios, threshold
# boundaries, remote failure modes (exit 3), redaction (unit table and end to
# end with sentinels), no raw logs left behind.
# --self-mutate: runs the suite against deliberately broken copies of the
# script and requires every mutant to be caught.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${POSTDEPLOY:-$HERE/postdeploy-logs.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAIL=0
N=0
ok() { N=$((N + 1)); echo "ok   $1"; }
bad() { N=$((N + 1)); echo "FAIL $1"; FAIL=$((FAIL + 1)); }

if [ "${1:-}" = --self-mutate ]; then
  M=$T/mut
  mkdir -p "$M"
  survived=0
  mutate() { # mutate <name> <sed-expr>
    sed -e "$2" "$HERE/postdeploy-logs.sh" >"$M/postdeploy-logs.sh"
    chmod +x "$M/postdeploy-logs.sh"
    if cmp -s "$HERE/postdeploy-logs.sh" "$M/postdeploy-logs.sh"; then echo "MUTANT $1: sed did not change the file"; survived=1; return; fi
    if POSTDEPLOY=$M/postdeploy-logs.sh "$HERE/test_postdeploy-logs.sh" >/dev/null 2>&1; then
      echo "MUTANT $1: SURVIVED (tests still pass)"; survived=1
    else
      echo "MUTANT $1: killed"
    fi
  }
  # redaction rules: delete one rule line (each rule is one line ending in a backslash)
  mutate "redact-no-cookie" '/set-cookie|cookies/d'
  mutate "redact-no-authorization" '/proxy-)?authorization/d'
  mutate "redact-no-keyvalue" '/x-api-key|api\[_-\]/d'
  mutate "redact-no-bearer" '/Bearer\[\[:space/d'
  mutate "redact-no-basic" '/Basic\[\[:space/d'
  mutate "redact-no-urlcreds" '/(:\/\/)/d'
  mutate "redact-no-email" '/\[EMAIL\]/d'
  mutate "redact-no-encoded-email" 's/(@|%40)/(@)/'
  mutate "redact-no-jwt" '/\[JWT\]/d'
  mutate "redact-no-uuid" '/\[UUID\]/d'
  mutate "redact-no-hex" '/\[HEX\]/d'
  mutate "redact-no-ipv6" '/\[IPV6\]/d'
  mutate "redact-no-ipv4" '/\[IPV4\]/d'
  mutate "redact-no-token" '/\[TOKEN\]/d'
  mutate "redact-ipv4-only-last-octet" 's/\[0-9\]{1,3}(\\\\.\[0-9\]{1,3}){3}\/\[IPV4\]/[0-9]{1,3}\\\\.[0-9]{1,3}\\\\.[0-9]{1,3}\/[IPV4]/'
  mutate "redact-ipv6-no-mapped-v4" 's/(:\[0-9\]{1,3}(\\\\.\[0-9\]{1,3}){3})?//g'
  mutate "redact-not-case-insensitive" 's/\[REDACTED\]\/Ig"/[REDACTED]\/g"/'
  mutate "candidates-not-redacted" 's/| redact | cut/| cut/'
  # thresholds and counting
  mutate "threshold-ge" 's/\[ "\$2" -gt "\$3" \]/[ "$2" -ge "$3" ]/'
  mutate "threshold-lt" 's/\[ "\$2" -gt "\$3" \]/[ "$2" -lt "$3" ]/'
  mutate "over-exits-0" 's/^  exit 1$/  exit 0/'
  mutate "5xx-no-threshold" 's/^row http_5xx "\$c_5xx" "\$MAX_5XX"$/row http_5xx "$c_5xx" -/'
  mutate "503-no-threshold" 's/^row http_503 "\$c_503" "\$MAX_503"$/row http_503 "$c_503" -/'
  mutate "409unknown-no-threshold" 's/"\$c_409u" "\$MAX_409U"$/"$c_409u" -/'
  mutate "opened-no-threshold" 's/"\$c_open" "\$MAX_OPENED"$/"$c_open" -/'
  mutate "traceback-no-threshold" 's/"\$c_tb" "\$MAX_TB"$/"$c_tb" -/'
  mutate "liveerr-no-threshold" 's/"\$c_live" "\$MAX_LIVE"$/"$c_live" -/'
  mutate "closes-no-threshold" 's/"\$closes" "\$MAX_CLOSES"$/"$closes" -/'
  mutate "ratelimit-no-threshold" 's/"\$c_rl" "\$MAX_RL"$/"$c_rl" -/'
  mutate "closes-sum-misses-1013" 's/ + c_1013))/))/'
  mutate "5xx-regex-4xx" 's/status ~ \/\^5\//status ~ \/^4\//'
  mutate "503-status-wrong" 's/status == "503") c503++/status == "504") c503++/'
  mutate "429-not-counted" 's/status == "429") rl++/status == "428") rl++/'
  mutate "traceback-not-counted" 's/tb++; intb = 1/intb = 1/'
  mutate "traceback-line-not-kept" 's/cand("traceback: " line); intb = 0; next/intb = 0; next/'
  mutate "close-code-4429-missed" 's/4401|4403|4429|1013)\/)/4401|4403|4430|1013)\/)/'
  mutate "opened-text-changed" 's/opened in an editor during an api update")) opened++/opened in an editor during an api updatex")) opened++/'
  mutate "409-not-pages-only" 's/path ~ \/\\\/pages\\\/\//path ~ \/\\\/x\\\/\//'
  mutate "live-errors-not-live-only" 's/^  if (svc == "live") {$/  if (svc != "live") {/'
  # remote handling
  mutate "ssh-rc-ignored" 's/^if \[ "\$rc" != 0 \]; then$/if false; then/'
  mutate "no-section-check" 's/grep -qxF "\$MARK \$s" "\$RAW" ||/true ||/'
  mutate "zero-lines-clean" 's/^if \[ "\$total" = 0 \]; then$/if false; then/'
  mutate "dry-run-executes" 's/^if \[ "\$DRY" = 1 \]; then$/if false; then/'
  mutate "no-connect-timeout" 's/ -o ConnectTimeout=10//'
  mutate "no-batchmode" 's/(-o BatchMode=yes /(/'
  mutate "no-alive-interval" 's/ -o ServerAliveInterval=15//'
  mutate "no-overall-timeout" 's/&& TO=(timeout "\$TIMEOUT")//'
  mutate "window-not-passed" 's/ WINDOW=\$WINDOW MARK/ MARK/'
  mutate "tmp-not-removed" "s/^trap 'rm -rf \"\$TMPD\"' EXIT$/true/"
  # validation
  mutate "no-host-check" 's/^case "\$PVE_HOST" in.*$/true/'
  mutate "no-ctid-check" 's/^case "\$PLANE_CTID" in.*$/true/'
  mutate "no-appdir-abs-check" 's/^case "\$PLANE_APP_DIR" in \/\*) ;; \*) die.*$/true/'
  mutate "no-appdir-charset-check" 's/^case "\$PLANE_APP_DIR" in \*\[!.*$/true/'
  mutate "window-unit-optional" 's/\[1-9\]\[smh\]|//'
  mutate "window-any-value" 's/^        \*) die "--window must.*$/        *) WINDOW=$v ;;/'
  mutate "number-check-dropped" 's/isnum "\$v" || die "\$a needs a non-negative number"/true/'
  exit "$survived"
fi

mkdir -p "$T/bin" "$T/app" "$T/logs" "$T/tmp"
cat >"$T/bin/ssh" <<'EOF'
#!/bin/sh
# stub ssh: log the call, drop "-o X" options and the host, run the command locally
echo "ssh $*" >>"$STUB_LOG"
while [ "$1" = -o ]; do shift 2; done
shift
[ -n "${STUB_SSH_RC:-}" ] && exit "$STUB_SSH_RC"
[ -n "${STUB_SSH_SLEEP:-}" ] && sleep "$STUB_SSH_SLEEP"
[ -n "${STUB_SSH_EMPTY:-}" ] && exit 0
exec sh -c "$1"
EOF
cat >"$T/bin/pct" <<'EOF'
#!/bin/sh
echo "pct $*" >>"$STUB_LOG"
case "$1" in exec) shift 3; exec "$@" ;; esac
EOF
cat >"$T/bin/docker" <<'EOF'
#!/bin/sh
# stub docker: `compose ... logs ... <service>` prints $STUB_LOGDIR/<service>.log
echo "DOCKER[$(basename "$PWD")] $*" >>"$STUB_LOG"
for last; do :; done
case "$*" in *" logs "*) [ -f "$STUB_LOGDIR/$last.log" ] && cat "$STUB_LOGDIR/$last.log" ;; esac
[ "$last" = "${STUB_DOCKER_FAIL:-@none@}" ] && exit 1
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/pct" "$T/bin/docker"
export STUB_LOG="$T/log" STUB_LOGDIR="$T/logs" PATH="$T/bin:$PATH" TMPDIR="$T/tmp"
export PVE_HOST=pve.example.test PLANE_CTID=999 PLANE_APP_DIR="$T/app/plane-app"
SENTINEL="SENTINEL-not-a-real-secret-4711"
export LIVE_SERVER_SECRET_KEY=$SENTINEL
mkdir -p "$PLANE_APP_DIR"

run() { : >"$STUB_LOG"; OUT=$("$SCRIPT" "$@" 2>&1); RC=$?; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
hasre() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
nolog() { [ ! -s "$STUB_LOG" ]; }

# --- canned logs -------------------------------------------------------------
acc() { # acc <count> <method> <path> <status> [ip]
  local i
  for ((i = 0; i < $1; i++)); do
    printf '%s:41234 - - [08/Oct/2026:12:00:%02d +0000] "%s %s HTTP/1.1" %s 512 "-" "Mozilla/5.0"\n' "${5:-10.0.0.5}" "$((i % 60))" "$2" "$3" "$4"
  done
}
reset_logs() {
  rm -f "$STUB_LOGDIR"/*.log
  {
    acc 20 GET /api/v1/users/me/ 200
    acc 3 GET /api/v1/workspaces/w/projects/ 304
    acc 2 GET /api/v1/missing/ 404
    acc 2 PATCH /api/v1/workspaces/w/projects/p/pages/3fa85f64-5717-4562-b3fc-2c963f66afa6/ 200
    echo "[2026-10-08 12:00:00 +0000] [7] [INFO] Booting worker with pid: 7"
  } >"$STUB_LOGDIR/api.log"
  echo "[2026-10-08 12:00:00,123: INFO/MainProcess] Connected to amqp://[REDACTED]@rabbit:5672//" >"$STUB_LOGDIR/worker.log"
  echo "[2026-10-08 12:00:00,123: INFO/MainProcess] beat: Starting..." >"$STUB_LOGDIR/beat-worker.log"
  {
    echo "Server listening on port 3000"
    echo "LIVE_EVENTS: authentication failures, running count 2"
  } >"$STUB_LOGDIR/live.log"
}
addlog() { cat >>"$STUB_LOGDIR/$1.log"; }

echo "-- usage errors and hostile values: exit 2, nothing run"
reset_logs
for args in "--bogus" "--window" "--window 15" "--window 15x" "--window 0m" "--window 15m;id" "--window \$(id)m" "--window -5m" "--window 99999m" \
  "--top 0" "--top 51" "--top x" "--timeout 4" "--timeout 901" "--max-5xx" "--max-5xx -1" "--max-5xx 1x" "--max-5xx 1234567890" "extra"; do
  set -f
  # shellcheck disable=SC2086
  run $args
  set +f
  { [ "$RC" = 2 ] && nolog; } && ok "refused rc=2, no ssh: '$args'" || bad "usage '$args' rc=$RC"
done
run --max-5xx ""
{ [ "$RC" = 2 ] && nolog; } && ok "refused rc=2, no ssh: empty --max-5xx value" || bad "empty value rc=$RC"
for v in PVE_HOST PLANE_CTID PLANE_APP_DIR; do
  (unset "$v"; run; [ "$RC" = 2 ] && has "set PVE_HOST" && nolog) && ok "missing $v rejected" || bad "missing $v"
done
for h in '-oProxyCommand=x' 'host name' 'host;id' 'host$(id)' 'host`id`' "ho'st" 'host|x' 'host&x' 'host>x'; do
  (PVE_HOST=$h; run; [ "$RC" = 2 ] && nolog) && ok "PVE_HOST refused: $h" || bad "PVE_HOST $h"
done
for c in '12x' '1 2' '1;id' '-1' '$(id)' '1.5'; do
  (PLANE_CTID=$c; run; [ "$RC" = 2 ] && nolog) && ok "PLANE_CTID refused: $c" || bad "PLANE_CTID $c"
done
for d in 'relative/dir' '/a b' '/a;rm' '/a$(id)' '/a`id`' "/a'b" '/a|b' '/a&b' '/a"b' '/a*' '/a
b'; do
  (PLANE_APP_DIR=$d; run; [ "$RC" = 2 ] && nolog) && ok "PLANE_APP_DIR refused: $(printf '%s' "$d" | tr '\n' '~')" || bad "PLANE_APP_DIR $d"
done
(PLANE_APP_DIR='/a;rm'; run --dry-run; [ "$RC" = 2 ] && nolog) && ok "hostile value refused even with --dry-run" || bad "dry-run hostile"
has "$SENTINEL" && bad "secret leaked in an error" || ok "no secret in error output"

echo "-- dry-run"
run --dry-run
{ [ "$RC" = 0 ] && nolog && has "dry-run only" && has "ConnectTimeout=10" && has "BatchMode=yes" && has "--since \"\$WINDOW\"" && has "WINDOW=15m"; } \
  && ok "dry-run: rc 0, nothing called, command shown" || bad "dry-run rc=$RC"
run --dry-run --window 2h
{ [ "$RC" = 0 ] && has "WINDOW=2h"; } && ok "dry-run shows a custom window" || bad "dry-run window"
has "$SENTINEL" && bad "dry-run leaked the secret" || ok "dry-run prints no secret"

echo "-- clean run"
reset_logs
run
{ [ "$RC" = 0 ] && has "RESULT: clean" && has "log lines: api=28" && has "http_5xx"; } && ok "clean logs: rc 0" || bad "clean rc=$RC"
has "top distinct error lines" && has "none" && ok "clean: no error lines listed" || bad "clean list"
grep -q 'BatchMode=yes' "$STUB_LOG" && grep -q 'ConnectTimeout=10' "$STUB_LOG" && grep -q 'ServerAliveInterval=15' "$STUB_LOG" && grep -q 'ServerAliveCountMax=3' "$STUB_LOG" \
  && ok "ssh runs with BatchMode, ConnectTimeout and ServerAlive options" || bad "ssh options"
grep -q 'pct exec 999 -- env APP_DIR=' "$STUB_LOG" && ok "pct exec into the container" || bad "pct exec"
n=$(grep -c '^DOCKER.*logs --no-color --no-log-prefix --since 15m' "$STUB_LOG")
[ "$n" = 4 ] && ok "docker compose logs --since 15m for four services" || bad "docker calls: $n"
for s in api worker beat-worker live; do
  grep -q "^DOCKER.* logs .* $s\$" "$STUB_LOG" && ok "logs read for $s" || bad "logs for $s"
done
grep -q -- '-f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env' "$STUB_LOG" && ok "uses the two-file compose command" || bad "compose files"
grep -q ' config' "$STUB_LOG" && bad "compose config must never run" || ok "compose config never used"
has "$SENTINEL" && bad "env secret printed" || ok "env secret not printed"
grep -q "$SENTINEL" "$STUB_LOG" && bad "env secret in a command line" || ok "env secret not in any command line"
run --window 90s
grep -q 'since 90s' "$STUB_LOG" && ok "custom window passed to docker" || bad "window passthrough"

echo "-- 5xx threshold boundary"
reset_logs
acc 5 GET /api/v1/x/ 500 | addlog api
run
{ [ "$RC" = 0 ] && has "RESULT: clean"; } && ok "5 x 5xx with max 5: clean (boundary)" || bad "boundary at max rc=$RC"
acc 1 GET /api/v1/x/ 502 | addlog api
run
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: http_5xx" && has "OVER"; } && ok "6 x 5xx: rc 1" || bad "over rc=$RC"
run --max-5xx 6
{ [ "$RC" = 0 ]; } && ok "--max-5xx 6 accepts it" || bad "max-5xx option rc=$RC"
run --max-5xx 0
[ "$RC" = 1 ] && ok "--max-5xx 0 refuses it" || bad "max-5xx 0"
has "GET /api/v1/x/ 500" && ok "distinct 5xx line listed without the user agent" || bad "5xx line listing"
has "Mozilla" && bad "user agent leaked into the listing" || ok "no user agent in the listing"
reset_logs
acc 3 GET /api/v1/x/ 503 | addlog api
run --max-5xx 100
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: http_503"; } && ok "503 has its own threshold" || bad "503 rc=$RC"
run --max-5xx 100 --max-503 3
[ "$RC" = 0 ] && ok "503 at its maximum is clean" || bad "503 boundary rc=$RC"
reset_logs
acc 4 GET /api/v1/x/ 404 | addlog api
acc 3 GET "/api/v1/x/?token=abcdef&email=a@b.com" 499 | addlog api
run
[ "$RC" = 0 ] && ok "4xx are not 5xx" || bad "4xx counted rc=$RC"

echo "-- tracebacks"
reset_logs
addlog worker <<'EOF'
[2026-10-08 12:01:00,000: ERROR/ForkPoolWorker-1] Task plane.bgtasks.x[1] raised unexpected: ValueError('bad')
Traceback (most recent call last):
  File "/code/plane/bgtasks/x.py", line 10, in run
    raise ValueError("bad for jane.doe@example.com id 3fa85f64-5717-4562-b3fc-2c963f66afa6 from 192.168.1.20")
ValueError: bad for jane.doe@example.com id 3fa85f64-5717-4562-b3fc-2c963f66afa6 from 192.168.1.20
EOF
run
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: tracebacks" && hasre 'tracebacks +1 \[0\]'; } && ok "one traceback: rc 1" || bad "traceback rc=$RC"
has "worker: traceback: ValueError: bad for [EMAIL] id [UUID] from [IPV4]" && ok "exception line listed, redacted" || bad "traceback line"
has "jane.doe" && bad "email leaked" || ok "traceback email not leaked"
has "192.168" && bad "ip leaked" || ok "traceback ip not leaked"
hasre 'error_log_lines +1$' && ok "ERROR log line counted" || bad "error_log_lines"
run --max-tracebacks 1 --max-5xx 5
[ "$RC" = 0 ] && ok "--max-tracebacks 1 accepts one" || bad "max-tracebacks rc=$RC"
reset_logs
addlog api <<'EOF'
Traceback (most recent call last):
  File "a.py", line 1, in f
KeyError: 'x'

During handling of the above exception, another exception occurred:

Traceback (most recent call last):
  File "a.py", line 3, in g
TypeError: y
EOF
run
{ [ "$RC" = 1 ] && hasre 'tracebacks +2 ' && has "api: traceback: KeyError: 'x'" && has "api: traceback: TypeError: y"; } && ok "chained traceback counted twice, exception lines kept" || bad "chained"
has "During handling" && bad "chain separator listed" || ok "chain separator not listed as an error"

echo "-- page PATCH 409 loaded vs unknown, 503, opened during update"
reset_logs
acc 4 PATCH /api/v1/workspaces/w/projects/p/pages/3fa85f64-5717-4562-b3fc-2c963f66afa6/ 409 | addlog api
acc 1 GET /api/v1/workspaces/w/projects/p/pages/ 409 | addlog api
acc 2 PATCH /api/v1/workspaces/w/projects/p/pages/3fa85f64-5717-4562-b3fc-2c963f66afa6/ 503 | addlog api
run --max-409-unknown 10 --max-503 10 --max-5xx 10
{ [ "$RC" = 0 ] && hasre 'page_patch_409 +4' && hasre 'loaded_409 \(upper\) +4' && hasre 'unknown_409 +0 ' && hasre 'page_patch_503 +2'; } && ok "409 on PATCH pages counted (GET not), all loaded when no check failed" || bad "409 counts rc=$RC: $OUT"
addlog api <<'EOF'
live presence check failed for page 3fa85f64-5717-4562-b3fc-2c963f66afa6 (ConnectTimeout)
live presence check failed for page 3fa85f64-5717-4562-b3fc-2c963f66afa6 (ConnectTimeout)
EOF
run --max-409-unknown 10 --max-503 10 --max-5xx 10
{ hasre 'loaded_409 \(upper\) +2' && hasre 'unknown_409 +2 '; } && ok "unknown 409 = failed presence checks, loaded = rest" || bad "unknown split"
run --max-503 10 --max-5xx 10
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: unknown_409"; } && ok "unknown 409 over its default maximum 0: rc 1" || bad "unknown threshold rc=$RC"
run --max-409-unknown 2 --max-503 10 --max-5xx 10
[ "$RC" = 0 ] && ok "unknown 409 at its maximum is clean" || bad "unknown boundary rc=$RC"
reset_logs
echo "page 3fa85f64-5717-4562-b3fc-2c963f66afa6 was opened in an editor during an api update" | addlog api
run
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: opened_during_update"; } && ok "opened-during-update warning: rc 1" || bad "opened rc=$RC"
run --max-opened-during 1
[ "$RC" = 0 ] && ok "--max-opened-during 1 accepts one" || bad "opened boundary"

echo "-- live hub"
reset_logs
addlog live <<'EOF'
LIVE_EVENTS: socket closed code 4401 for a client
LIVE_EVENTS: closing with code 4403 origin not allowed
LIVE_EVENTS: close 4429 message rate
LIVE_EVENTS: close code=1013 try again later
LIVE_EVENTS: authentication failures, running count 7
LIVE_EVENTS: dropped invalid Redis messages, running count 3
connection from port 1013 accepted
EOF
run
{ [ "$RC" = 0 ] && hasre 'close_4401 .* +1' && hasre 'close_4403 .* +1' && hasre 'close_4429 .* +1' && hasre 'close_1013 .* +1' && hasre 'live_closes_total +4 ' \
  && hasre 'live_auth_failures +7' && hasre 'live_invalid_redis +3'; } && ok "close codes and running counts reported; unrelated 1013 ignored" || bad "live closes rc=$RC: $OUT"
run --max-closes 3
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: live_closes_total"; } && ok "closes over --max-closes 3: rc 1" || bad "closes rc=$RC"
run --max-closes 4
[ "$RC" = 0 ] && ok "closes at the maximum: clean" || bad "closes boundary"
reset_logs
echo "LIVE_EVENTS: subscriber error ECONNRESET for user bob@example.com" | addlog live
echo "Error: boom" | addlog api
run
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: live_errors" && has "live: LIVE_EVENTS: subscriber error ECONNRESET for user [EMAIL]"; } && ok "live error: rc 1, line redacted" || bad "live error rc=$RC"
hasre 'live_errors +1 ' && ok "only live lines count as live errors" || bad "live_errors count"
run --max-live-errors 1
[ "$RC" = 0 ] && ok "--max-live-errors 1 accepts one" || bad "live-errors boundary"
reset_logs
acc 11 GET /api/v1/x/ 429 | addlog api
run
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: rate_limit_overflows"; } && ok "429 answers count as rate-limit overflows" || bad "429 rc=$RC"
run --max-ratelimit 11
[ "$RC" = 0 ] && ok "rate limits at the maximum: clean" || bad "ratelimit boundary"
reset_logs
echo "LIVE_EVENTS: rate limit overflow, full refresh sent" | addlog live
for i in 1 2 3 4 5 6 7 8 9 10 11; do echo "rate limit overflow $i"; done | addlog worker
run
{ [ "$RC" = 1 ] && has "OVER THRESHOLD: rate_limit_overflows"; } && ok "rate-limit overflow log lines counted" || bad "rl lines rc=$RC"

echo "-- remote failure modes: exit 3, fail closed"
reset_logs
(export STUB_SSH_RC=255; run; [ "$RC" = 3 ] && has "remote call failed" && ! has "RESULT: clean") && ok "ssh failure: rc 3" || bad "ssh failure"
(export STUB_DOCKER_FAIL=live; run; [ "$RC" = 3 ] && ! has "RESULT: clean") && ok "docker failure on one service: rc 3" || bad "docker failure"
(export STUB_SSH_EMPTY=1; run; [ "$RC" = 3 ] && has "incomplete remote output") && ok "no output at all: rc 3" || bad "empty output"
(export STUB_SSH_SLEEP=8; run --timeout 5; [ "$RC" = 3 ] && has "timed out") && ok "overall timeout: rc 3" || bad "timeout"
rm -f "$STUB_LOGDIR"/*.log
run
{ [ "$RC" = 3 ] && has "no log lines at all"; } && ok "sections present but no log lines at all: rc 3, not clean" || bad "zero lines rc=$RC"
reset_logs
: >"$STUB_LOGDIR/beat-worker.log"
run
{ [ "$RC" = 0 ] && has "WARN: no log lines from beat-worker"; } && ok "one quiet service: warning only" || bad "quiet service rc=$RC"
reset_logs
echo "@@PDL-1@@ END" | addlog api
echo "@@PDL-1@@ live" | addlog api
acc 6 GET /x/ 500 | addlog api
run
[ "$RC" = 1 ] && ok "forged marker lines in a log do not break the sections" || bad "forged marker rc=$RC"

echo "-- redaction unit table (--redact-stdin)"
rd() { printf '%s\n' "$1" | "$SCRIPT" --redact-stdin; }
nogo() { # nogo <name> <input> <forbidden...>: output must not contain any forbidden text
  local name=$1 in=$2 out f
  shift 2
  out=$(rd "$in")
  for f in "$@"; do
    case "$out" in *"$f"*) bad "redact $name leaked '$f' -> $out"; return ;; esac
  done
  ok "redact $name"
}
want() { # want <name> <input> <exact output>
  local out
  out=$(rd "$2")
  [ "$out" = "$3" ] && ok "redact $1" || bad "redact $1: got '$out'"
}
want email "mail jane.doe+tag@Example.co.uk sent" "mail [EMAIL] sent"
want email-encoded "GET /u?e=jane%40example.com" "GET /u?e=[EMAIL]"
want email-two "a@b.io and c.d@e.org" "[EMAIL] and [EMAIL]"
nogo email-quoted "user='o'brien@example.com'" "brien@example.com" "example.com"
want uuid "page 3fa85f64-5717-4562-b3fc-2c963f66afa6 done" "page [UUID] done"
want uuid-upper "ID 3FA85F64-5717-4562-B3FC-2C963F66AFA6" "ID [UUID]"
want uuid-in-path "/pages/3fa85f64-5717-4562-b3fc-2c963f66afa6/" "/pages/[UUID]/"
want hex24 "obj 507f1f77bcf86cd799439011 x" "obj [HEX] x"
want ipv4 "from 10.1.2.3:5555 to 255.255.255.255" "from [IPV4]:5555 to [IPV4]"
want ipv4-forwarded "x-forwarded-for 203.0.113.9, 198.51.100.7" "x-forwarded-for [IPV4], [IPV4]"
want ipv6-loopback "peer ::1 up" "peer [IPV6] up"
want ipv6-compressed "peer 2001:db8::8a2e:370:7334 up" "peer [IPV6] up"
want ipv6-full "peer 2001:0db8:85a3:0000:0000:8a2e:0370:7334 up" "peer [IPV6] up"
want ipv6-link-local "peer fe80::1 up" "peer [IPV6] up"
want ipv6-trailing-compress "net 2001:db8:: up" "net [IPV6] up"
want ipv6-bracket-port "[2001:db8::1]:8080" "[[IPV6]]:8080"
want ipv6-mapped "peer ::ffff:192.168.0.1 up" "peer [IPV6] up"
want ipv6-uppercase "peer FE80::ABCD up" "peer [IPV6] up"
want time-untouched "at 12:34:56 done" "at 12:34:56 done"
want scope-untouched "std::string and Foo::bar" "std::string and Foo::bar"
want bearer "token Bearer abc.def-ghi_123~+/= end" "token Bearer [REDACTED] end"
want bearer-lower "bearer abcdef123456" "Bearer [REDACTED]"
want authorization-header "Authorization: Bearer abc123xyz" "Authorization: [REDACTED]"
want authorization-basic "authorization: Basic dXNlcjpwYXNzd29yZA==" "authorization: [REDACTED]"
want authorization-json '{"authorization": "Bearer abc", "n": 1}' '{"authorization: [REDACTED]", "n": 1}'
want proxy-authorization "Proxy-Authorization: Basic dXNlcjpwYXNzd29yZA==" "Proxy-Authorization: [REDACTED]"
want basic-bare "got Basic dXNlcjpwYXNzd29yZA== here" "got Basic [REDACTED] here"
want api-key-header "X-Api-Key: sk_live_123456" "X-Api-Key=[REDACTED]"
want api-key-lower "x-api-key: plane_api_abcdef" "x-api-key=[REDACTED]"
want api-key-json '{"api_key": "k123"}' '{"api_key=[REDACTED]"}'
want api-key-query "GET /x?api_key=abc123&y=1" "GET /x?api_key=[REDACTED]&y=1"
want secret-header "live-server-secret-key: change-me-now" "live-server-secret-key=[REDACTED]"
want token-query "GET /x?token=abc123&y=1" "GET /x?token=[REDACTED]&y=1"
want access-token "access_token=abc123" "access_token=[REDACTED]"
want password "password=hunter2 next" "password=[REDACTED] next"
want session-id "sessionid=abcdef12345 x" "sessionid=[REDACTED] x"
want csrf "csrftoken=abc123 x" "csrftoken=[REDACTED] x"
want cookie-header "Cookie: session-id=abc; csrftoken=zzz; other=1" "Cookie: [REDACTED]"
want set-cookie "Set-Cookie: sessionid=abc; Path=/; HttpOnly" "Set-Cookie: [REDACTED]"
want cookie-lower "cookie: a=b" "cookie: [REDACTED]"
want cookie-after-text "request headers cookie: a=b; c=d" "request headers cookie: [REDACTED]"
want jwt "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnc2ln end" "jwt [JWT] end"
want url-credentials "redis://user:pa55@cache:6379/0" "redis://[REDACTED]@cache:6379/0"
want long-token "k Abcdefghijklmnopqrstuvwxyz0123456789_-AB end" "k [TOKEN] end"
want plain-text-kept "ERROR task failed after 3 retries (code 4429)" "ERROR task failed after 3 retries (code 4429)"
want path-kept "GET /api/v1/workspaces/w/projects/ 200" "GET /api/v1/workspaces/w/projects/ 200"
want mixed "jane@x.io from 10.0.0.1 token=abc id 3fa85f64-5717-4562-b3fc-2c963f66afa6" "[EMAIL] from [IPV4] token=[REDACTED] id [UUID]"
for s in "jane@x.io from 10.0.0.1 token=abc Bearer qq2wwe3rrr4tt" "Cookie: a=b" "peer 2001:db8::1 up" "x-api-key: k Authorization: Bearer z"; do
  a=$(rd "$s")
  b=$(printf '%s\n' "$a" | "$SCRIPT" --redact-stdin)
  [ "$a" = "$b" ] && ok "redaction is idempotent: $s" || bad "idempotence: '$a' vs '$b'"
done
out=$(printf 'a\033[31mb\rc\n' | "$SCRIPT" --redact-stdin)
[ "$out" = "abc" ] && ok "control characters stripped" || bad "control characters: '$out'"
"$SCRIPT" --redact-stdin extra </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "--redact-stdin takes no other arguments" || bad "redact-stdin args"

echo "-- redaction end to end: sentinels in every service log never reach the output"
reset_logs
addlog api <<'EOF'
10.9.8.7:1 - - [08/Oct/2026:12:00:00 +0000] "GET /api/v1/users/zed.person@example.com/?token=TOKSECRET1234&k=1 HTTP/1.1" 500 1 "-" "UA-SENTINEL"
Traceback (most recent call last):
  File "x.py", line 1, in f
RuntimeError: failed for zed.person@example.com ip 203.0.113.77 ip6 2001:db8::5 id 11111111-2222-3333-4444-555555555555 Authorization: Bearer BEARSECRET99 x-api-key: APIKEYSECRET9 cookie: sessionid=COOKSECRET9
EOF
addlog live <<'EOF'
Error: handshake failed for zed.person@example.com from 203.0.113.78 cookie: session-id=COOKSECRET8 api_key=APIKEYSECRET8
EOF
addlog worker <<'EOF'
[2026-10-08 12:00:00,000: ERROR/MainProcess] sending to zed.person@example.com password=PWSECRET7 redis://user:URLSECRET6@cache:6379/0
EOF
run --max-5xx 100 --max-tracebacks 100 --max-live-errors 100
{ [ "$RC" = 0 ] && has "RESULT: clean"; } && ok "sentinel run completes" || bad "sentinel run rc=$RC"
leak=
for s in zed.person example.com 203.0.113 2001:db8 11111111-2222 BEARSECRET99 APIKEYSECRET9 APIKEYSECRET8 COOKSECRET9 COOKSECRET8 PWSECRET7 URLSECRET6 TOKSECRET1234 UA-SENTINEL 10.9.8.7 "$SENTINEL"; do
  has "$s" && leak="$leak $s"
done
[ -z "$leak" ] && ok "no sentinel in the output" || bad "leaked:$leak"
has "[EMAIL]" && has "[IPV4]" && has "[IPV6]" && has "[UUID]" && ok "placeholders present in the listing" || bad "placeholders"
grep -c . "$STUB_LOG" >/dev/null
for s in zed.person BEARSECRET99 COOKSECRET9; do grep -q "$s" "$STUB_LOG" && bad "log content in a command line: $s"; done
ok "log content never appears in a command line"
left=$(find "$T/tmp" -mindepth 1 | wc -l)
[ "$left" = 0 ] && ok "no raw log file left in the temporary directory" || bad "temp files left: $left"
run --window 15m
left=$(find "$T/tmp" -mindepth 1 | wc -l)
(export STUB_SSH_RC=255; run)
left2=$(find "$T/tmp" -mindepth 1 | wc -l)
[ "$left" = 0 ] && [ "$left2" = 0 ] && ok "temporary directory removed on success and failure" || bad "temp left $left $left2"

echo "-- top list"
reset_logs
for i in 1 2 3; do acc 1 GET "/api/v1/a$i/" 500; done | addlog api
acc 4 GET /api/v1/a1/ 500 | addlog api
run --max-5xx 100 --top 2
c=$(printf '%s\n' "$OUT" | sed -n '/^top distinct/,/^RESULT/p' | grep -c 'api: GET')
{ [ "$c" = 2 ] && printf '%s\n' "$OUT" | grep -q '5 api: GET /api/v1/a1/ 500'; } && ok "--top limits the list, most frequent first" || bad "top list ($c)"

echo
echo "$N checks, $FAIL failed"
[ "$FAIL" = 0 ]
