#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# test_fetch-images.sh - exercises fetch-images.sh with a stub verify-load.sh,
# local paths, file:// URLs and a throwaway HTTP server on the loopback
# interface. Needs bash, coreutils, curl and python3. No internet.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
FAIL=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAIL=1; }

mkdir -p "$T/src" "$T/www"
printf 'not really an image archive\n' >"$T/src/plane-fork-live.7.tar"
cp "$T/src/plane-fork-live.7.tar" "$T/www/"
GOOD=$(sha256sum "$T/src/plane-fork-live.7.tar" | awk '{print $1}')
BAD=$(printf 'x' | sha256sum | awk '{print $1}')

# Stub for verify-load.sh: records its arguments and what the sha file holds.
cat >"$T/verify-load.sh" <<'STUB'
#!/bin/bash
echo "verify-load $*" >>"$STUB_LOG"
cat "$2" >>"$STUB_LOG"
exit "${STUB_RC:-0}"
STUB
export STUB_LOG="$T/log" VERIFY_LOAD="$T/verify-load.sh"

# Stub curl on PATH: records its arguments, then runs the real curl.
REAL_CURL=$(command -v curl)
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<STUB
#!/bin/sh
echo "\$*" >>"\$CURL_LOG"
exec "$REAL_CURL" "\$@"
STUB
chmod +x "$T/bin/curl"
export CURL_LOG="$T/curl.log" PATH="$T/bin:$PATH"

run() { : >"$STUB_LOG"; OUT=$("$HERE/fetch-images.sh" "$@" 2>&1); RC=$?; }
nothing_stored() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

# local path, good hash
run "$T/src/plane-fork-live.7.tar" "$GOOD" "$T/d1"
[ "$RC" = 0 ] && ok "local path, good hash exits 0" || bad "good local rc=$RC ($OUT)"
cmp -s "$T/d1/plane-fork-live.7.tar" "$T/src/plane-fork-live.7.tar" && ok "archive stored" || bad "archive not stored"
grep -q "^verify-load $T/d1/plane-fork-live.7.tar $T/d1/plane-fork-live.7.sha256\$" "$STUB_LOG" && ok "hands off to verify-load.sh" || bad "no hand-off"
grep -q "^$GOOD  plane-fork-live.7.tar\$" "$STUB_LOG" && ok "sha256 file written for verify-load" || bad "sha256 file content"

# upper-case digest accepted
run "$T/src/plane-fork-live.7.tar" "$(echo "$GOOD" | tr a-f A-F)" "$T/d1b"
[ "$RC" = 0 ] && ok "upper-case digest accepted" || bad "upper-case rc=$RC"

# bad hash
run "$T/src/plane-fork-live.7.tar" "$BAD" "$T/d2"
[ "$RC" != 0 ] && echo "$OUT" | grep -q 'sha256 mismatch' && ok "bad hash refused" || bad "bad hash rc=$RC"
nothing_stored "$T/d2" && ok "bad hash leaves nothing in the destination" || bad "bad hash left files: $(ls -A "$T/d2")"
[ ! -s "$STUB_LOG" ] && ok "bad hash does not reach verify-load" || bad "bad hash reached verify-load"

# malformed expected values
for v in "" abc "${GOOD}00" "${GOOD%?}g"; do
  run "$T/src/plane-fork-live.7.tar" "$v" "$T/d3"
  [ "$RC" != 0 ] && [ ! -s "$STUB_LOG" ] && ok "malformed digest '${v:0:8}' refused" || bad "malformed digest '${v:0:8}' rc=$RC"
done
nothing_stored "$T/d3" && ok "malformed digests store nothing" || bad "malformed digests left files"

# missing file
run "$T/src/plane-fork-live.9.tar" "$GOOD" "$T/d4"
[ "$RC" != 0 ] && echo "$OUT" | grep -q 'file not found' && ok "missing file refused" || bad "missing file rc=$RC"
nothing_stored "$T/d4" && ok "missing file stores nothing" || bad "missing file left files"

# empty file
: >"$T/src/plane-fork-live.8.tar"
run "$T/src/plane-fork-live.8.tar" "$GOOD" "$T/d5"
[ "$RC" != 0 ] && nothing_stored "$T/d5" && ok "empty file refused" || bad "empty file rc=$RC"

# bad name
cp "$T/src/plane-fork-live.7.tar" "$T/src/notes.txt"
run "$T/src/notes.txt" "$GOOD" "$T/d6"
[ "$RC" != 0 ] && ok "non-.tar name refused" || bad "non-tar rc=$RC"

# file:// URL
run "file://$T/src/plane-fork-live.7.tar" "$GOOD" "$T/d7"
[ "$RC" = 0 ] && cmp -s "$T/d7/plane-fork-live.7.tar" "$T/src/plane-fork-live.7.tar" && ok "file:// URL, good hash" || bad "file:// rc=$RC"
run "file://$T/src/plane-fork-live.7.tar" "$BAD" "$T/d8"
[ "$RC" != 0 ] && nothing_stored "$T/d8" && ok "file:// URL, bad hash refused" || bad "file:// bad rc=$RC"
run "file://$T/src/nope.tar" "$GOOD" "$T/d9"
[ "$RC" != 0 ] && nothing_stored "$T/d9" && ok "file:// URL, missing file refused" || bad "file:// missing rc=$RC"

# verify-load failure propagates
STUB_RC=1 run "$T/src/plane-fork-live.7.tar" "$GOOD" "$T/d10"
[ "$RC" = 1 ] && ok "verify-load failure propagates" || bad "verify-load rc propagate rc=$RC"

# SKIP_LOAD
SKIP_LOAD=1 run "$T/src/plane-fork-live.7.tar" "$GOOD" "$T/d11"
[ "$RC" = 0 ] && [ -f "$T/d11/plane-fork-live.7.sha256" ] && [ ! -s "$STUB_LOG" ] && ok "SKIP_LOAD stores and verifies without loading" || bad "SKIP_LOAD rc=$RC"

# FORK_N passed through
FORK_N=12 run "$T/src/plane-fork-live.7.tar" "$GOOD" "$T/d12"
grep -q '^verify-load .* 12$' "$STUB_LOG" && ok "FORK_N passed to verify-load" || bad "FORK_N not passed"

# expected hash from the environment
FETCH_EXPECTED_SHA256="$GOOD" run "$T/src/plane-fork-live.7.tar" "" "$T/d13"
# (second argument empty falls through to the environment value)
[ "$RC" = 0 ] && ok "FETCH_EXPECTED_SHA256 used when the argument is empty" || bad "env digest rc=$RC"

# HTTP: plain http refused by default
run "http://127.0.0.1:9/plane-fork-live.7.tar" "$GOOD" "$T/d14"
[ "$RC" != 0 ] && echo "$OUT" | grep -q 'plain http is refused' && ok "plain http refused by default" || bad "http default rc=$RC"
run "ftp://example.invalid/plane-fork-live.7.tar" "$GOOD" "$T/d14"
[ "$RC" != 0 ] && ok "other schemes refused" || bad "ftp rc=$RC"

# https branch: the real download cannot run offline, so point it at a closed
# loopback port. It must fail, leave nothing, and call curl with the safety flags.
: >"$CURL_LOG"
run "https://127.0.0.1:9/plane-fork-live.7.tar" "$GOOD" "$T/d19"
[ "$RC" != 0 ] && nothing_stored "$T/d19" && ok "https to a closed port refused" || bad "https closed port rc=$RC"
for want in '-fsSL' '--proto =https' '--proto-redir =https' '--retry 3' '--connect-timeout 30' '--speed-limit 1000' '--speed-time 60'; do
  grep -qF -- "$want" "$CURL_LOG" && ok "https curl call has $want" || bad "https curl call lacks $want"
done
grep -q -- '--max-time' "$CURL_LOG" && bad "https curl call has a total --max-time" || ok "no total --max-time"

# HTTP on loopback
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  (cd "$T/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  SRV=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
  export FETCH_ALLOW_HTTP=1
  run "http://127.0.0.1:$PORT/plane-fork-live.7.tar?download=1" "$GOOD" "$T/d15"
  [ "$RC" = 0 ] && cmp -s "$T/d15/plane-fork-live.7.tar" "$T/src/plane-fork-live.7.tar" && ok "http download, good hash" || bad "http good rc=$RC ($OUT)"
  run "http://127.0.0.1:$PORT/plane-fork-live.7.tar" "$BAD" "$T/d16"
  [ "$RC" != 0 ] && nothing_stored "$T/d16" && ok "http download, bad hash refused" || bad "http bad rc=$RC"
  run "http://127.0.0.1:$PORT/plane-fork-live.99.tar" "$GOOD" "$T/d17"
  [ "$RC" != 0 ] && echo "$OUT" | grep -q 'download failed' && nothing_stored "$T/d17" && ok "http 404 refused" || bad "http 404 rc=$RC"
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
  run "http://127.0.0.1:$PORT/plane-fork-live.7.tar" "$GOOD" "$T/d18"
  [ "$RC" != 0 ] && nothing_stored "$T/d18" && ok "unreachable server refused" || bad "unreachable rc=$RC"
  unset FETCH_ALLOW_HTTP
else
  bad "curl and python3 are required for the HTTP tests"
fi

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
