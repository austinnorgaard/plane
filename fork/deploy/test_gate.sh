#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# test_gate.sh - exercises gate.sh: every check passes and fails, secrets are
# never printed, exit codes are right. Uses a local bare repository as origin, a
# stub ssh in place of the hypervisor, and the real fetch-images.sh. Needs bash,
# git and coreutils.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE=${GATE_UNDER_TEST:-$HERE/gate.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAIL=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAIL=1; }
GIT="git -c user.name=t -c user.email=t@example.test"

# --- git fixture: bare origin with the release branch, a clone, one off-branch commit
git init -q --bare "$T/origin.git"
git init -q "$T/work"
( cd "$T/work" && $GIT checkout -q -b live-updates/v1.4.2 && echo a >f && git add f && $GIT commit -qm one &&
  git remote add origin "$T/origin.git" && git push -q origin live-updates/v1.4.2 2>/dev/null &&
  git checkout -q -b side && echo b >g && git add g && $GIT commit -qm side )
SHA=$(git -C "$T/work" rev-parse live-updates/v1.4.2)
SIDE=$(git -C "$T/work" rev-parse side)
export GATE_REPO="$T/work"

# --- stub ssh: stands for the hypervisor; never sees a secret
mkdir -p "$T/bin"
cat >"$T/bin/ssh" <<'STUB'
#!/bin/sh
echo "ssh $*" >>"$STUB_LOG"
cat >/dev/null
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
if [ "${STUB_INSPECT_RC:-0}" = 0 ]; then echo "RESULT: no STOP lines"; else echo "STOP: stub reason"; echo "RESULT: 1 STOP line(s); do not deploy, escalate"; fi
exit "${STUB_INSPECT_RC:-0}"
STUB
chmod +x "$T/bin/ssh"
export GIT_TERMINAL_PROMPT=0 STUB_LOG="$T/log" PATH="$T/bin:$PATH"

# --- inputs
SENTINEL="SENTINEL-not-a-real-secret-4711"
printf 'QA: PASS @ %s\n' "${SHA:0:12}" >"$T/qa"
# mktar <file> <label-sha-or-NONE> [images]: a docker-archive style tar (manifest.json + image configs)
mktar() {
  local f=$1 lab=$2 n=${3:-3} i d
  d=$(mktemp -d -p "$T")
  : >"$d/m"
  for i in $(seq 1 "$n"); do
    if [ "$lab" = NONE ]; then printf '{"architecture":"amd64","config":{"Labels":{"other":"x"}}}' >"$d/cfg$i.json"
    else printf '{"architecture":"amd64","config":{"Labels":{"other":"x","plane-fork-build":"%s"}}}' "$lab" >"$d/cfg$i.json"; fi
    printf '%s{"Config":"cfg%s.json","RepoTags":["localhost/plane-fork-img%s:v1.4.2-live.1"],"Layers":[]}' "$([ "$i" -gt 1 ] && echo ,)" "$i" "$i" >>"$d/m"
  done
  { printf '['; cat "$d/m"; printf ']'; } >"$d/manifest.json"
  ( cd "$d" && tar -cf "$f" manifest.json cfg*.json )
  rm -rf "$d"
}
mktar "$T/plane-fork-live.1.tar" "$SHA"
TARSHA=$(sha256sum "$T/plane-fork-live.1.tar" | awk '{print $1}')
# a filled copy of the runbook table: take the real file and fill every empty result cell
awk '/^### Inspection results/{s=1;print;next} s&&/^## /{s=0}
     s&&/^\|/&&!/^\| Item/&&!/^\| -/{sub(/\|[ ]*\|$/,"| recorded |")} {print}' "$HERE/RUNBOOK.md" >"$T/runbook.filled"
cat >"$T/env" <<EOT
LIVE_EVENTS_TRUSTED_PROXIES=10.0.0.0/8,192.0.2.1,2001:db8::/32
PAGES_REBASE_MAX_HTML_BYTES=524288
PAGES_API_MAX_HTML_BYTES=262144
PAGES_REBASE_WORKER_MAX_MB=512
NODE_OPTIONS=--trace-warnings
LIVE_SERVER_SECRET_KEY=$SENTINEL
EOT
export QA_RECORD="$T/qa" IMAGE_TAR="$T/plane-fork-live.1.tar" IMAGE_SHA256="$TARSHA"
export RUNBOOK_FILE="$T/runbook.filled" STOCK_RELEASE=v1.4.2
export PVE_HOST=pve.example.test PLANE_CTID=999 PLANE_APP_DIR=/opt/plane-app
unset STUB_INSPECT_RC BUILD_NOTES

run() { : >"$STUB_LOG"; OUT=$("$GATE" "$@" 2>&1); RC=$?; }
good() { run -e "$T/env" "$SHA"; }
expect_fail() { # expect_fail <label> <item substring>: NO-GO, exit 1, that item FAILs
  [ "$RC" = 1 ] && echo "$OUT" | grep -q "^FAIL .*$2" && echo "$OUT" | grep -q '^RESULT: NO-GO' && ok "$1" || bad "$1 (rc=$RC)"
}
setting() { # setting <KEY> <value or UNSET>: rewrite the env file
  grep -v "^$1=" "$T/env.base" >"$T/env"; [ "$2" = UNSET ] || echo "$1=$2" >>"$T/env"
}
cp "$T/env" "$T/env.base"

good
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^RESULT: GO$' && ok "all good: GO, exit 0" || { bad "all good rc=$RC"; echo "$OUT"; }
[ "$(echo "$OUT" | grep -c '^PASS ')" -ge 12 ] && ok "every check prints PASS" || bad "PASS count"
echo "$OUT" | grep -q '^FAIL' && bad "unexpected FAIL in good run" || ok "no FAIL in good run"
if echo "$OUT" | grep -q "$SENTINEL" || grep -q "$SENTINEL" "$STUB_LOG"; then bad "secret leaked"; else ok "secret absent from output and ssh arguments"; fi

# usage
run; [ "$RC" = 2 ] && ok "no argument: exit 2" || bad "no argument rc=$RC"
run abc; [ "$RC" = 2 ] && ok "short sha: exit 2" || bad "short sha rc=$RC"
run --bogus "$SHA"; [ "$RC" = 2 ] && ok "unknown option: exit 2" || bad "unknown option rc=$RC"
run -e "$T/nonexistent" "$SHA"; [ "$RC" = 2 ] && ok "unreadable env file: exit 2" || bad "env file rc=$RC"
run -e; [ "$RC" = 2 ] && ok "-e without value: exit 2" || bad "-e rc=$RC"

# 1 sha on branch
run -e "$T/env" "$SIDE"; expect_fail "sha not on branch -> FAIL" "release sha is on"
run -e "$T/env" 0123456789012345678901234567890123456789; expect_fail "unknown sha -> FAIL" "release sha is on"
GATE_REPO="$T/nowhere" run -e "$T/env" "$SHA"; expect_fail "no checkout -> FAIL" "release sha is on"
# a stale clone must be refreshed: push a new commit to origin, check it without fetching by hand
( cd "$T/work" && git checkout -q live-updates/v1.4.2 && echo c >h && git add h && $GIT commit -qm two && git push -q origin live-updates/v1.4.2 2>/dev/null )
NEW=$(git -C "$T/work" rev-parse HEAD)
git -C "$T/work" update-ref refs/remotes/origin/live-updates/v1.4.2 "$SHA"
printf 'QA: PASS @ %s\n' "$NEW" >"$T/qa"
mktar "$T/new.tar" "$NEW"; cp "$T/new.tar" "$T/plane-fork-live.9.tar"
IMAGE_TAR="$T/plane-fork-live.9.tar" IMAGE_SHA256=$(sha256sum "$T/new.tar" | awk '{print $1}') run -e "$T/env" "$NEW"
[ "$RC" = 0 ] && ok "gate fetches origin first (stale ref refreshed)" || bad "stale ref rc=$RC"
printf 'QA: PASS @ %s\n' "${SHA:0:12}" >"$T/qa"

# 2 QA
printf 'QA: PASS @ %s\n' "$SIDE" >"$T/qa"; good; expect_fail "QA PASS names another sha -> FAIL" "QA PASS"
printf 'QA: FAIL @ %s\n' "${SHA:0:12}" >"$T/qa"; good; expect_fail "QA FAIL line -> FAIL" "QA PASS"
printf 'QA: PASS @ %s\nQA: FAIL @ %s\n' "${SHA:0:10}" "${SHA:0:7}" >"$T/qa"; good; expect_fail "PASS then FAIL for same sha -> FAIL" "QA PASS"
printf 'QA: PASS @ %s\n' "${SHA:0:5}" >"$T/qa"; good; expect_fail "sha shorter than 7 digits -> FAIL" "QA PASS"
printf 'nothing here\n' >"$T/qa"; good; expect_fail "no QA line -> FAIL" "QA PASS"
QA_RECORD="$T/none" run -e "$T/env" "$SHA"; expect_fail "QA_RECORD missing -> FAIL" "QA PASS"
printf 'QA: PASS @ %s\r\n' "$SHA" >"$T/qa"; good; [ "$RC" = 0 ] && ok "full sha with CRLF passes" || bad "CRLF rc=$RC"
printf 'QA: PASS @ %s\n' "${SHA:0:12}" >"$T/qa"

# 3 archive
IMAGE_SHA256=$(printf '0%.0s' $(seq 64)) run -e "$T/env" "$SHA"; expect_fail "archive sha mismatch -> FAIL" "image archive sha256"
IMAGE_SHA256="" run -e "$T/env" "$SHA"; expect_fail "no expected sha -> FAIL" "image archive sha256"
IMAGE_TAR="$T/none.tar" run -e "$T/env" "$SHA"; expect_fail "archive missing -> FAIL" "image archive sha256"
printf 'Build ok\nSHA verified: %s is in origin/live-updates/v1.4.2\nTar sha256: %s\n' "$SHA" "$TARSHA" >"$T/notes"
IMAGE_SHA256="" BUILD_NOTES="$T/notes" run -e "$T/env" "$SHA"; [ "$RC" = 0 ] && ok "sha from BUILD_NOTES line passes" || bad "BUILD_NOTES rc=$RC"
printf 'SHA verified: %s is in origin/live-updates/v1.4.2\nTar sha256: %s\n' "$SHA" "$(printf '1%.0s' $(seq 64))" >"$T/notes"
IMAGE_SHA256="" BUILD_NOTES="$T/notes" run -e "$T/env" "$SHA"; expect_fail "BUILD_NOTES with another sha -> FAIL" "image archive sha256"
# 3b archive bound to the release sha
OTHER=$(printf 'a%.0s' $(seq 40))
bindrun() { # bindrun <label-or-NONE> [images]: new archive, matching IMAGE_SHA256
  mktar "$T/b/plane-fork-live.1.tar" "$1" "${2:-3}"
  IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$(sha256sum "$T/b/plane-fork-live.1.tar" | awk '{print $1}') run -e "$T/env" "$SHA"
}
mkdir -p "$T/b"
bindrun "$SHA"; [ "$RC" = 0 ] && echo "$OUT" | grep -q 'bound to the release sha (label=ok' && ok "all images labelled with the sha: bound" || bad "labelled archive rc=$RC"
bindrun "$OTHER"; expect_fail "images labelled with another sha -> FAIL" "bound to the release sha"
bindrun NONE; expect_fail "no label, no notes -> FAIL (not bound)" "bound to the release sha"
echo "$OUT" | grep -q 'archive not bound' && ok "unbound message is visible" || bad "unbound message"
bindrun "$SHA" 2; expect_fail "only two labelled images -> FAIL" "bound to the release sha"
printf 'plain text, not a tar' >"$T/b/plane-fork-live.1.tar"
IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$(sha256sum "$T/b/plane-fork-live.1.tar" | awk '{print $1}') run -e "$T/env" "$SHA"; expect_fail "not a tar -> FAIL (not bound)" "bound to the release sha"
# one image with another label among good ones
mktar "$T/b/x.tar" "$SHA"; mkdir "$T/b/x"; ( cd "$T/b/x" && tar -xf ../x.tar && sed -i "s/$SHA/$OTHER/" cfg2.json && tar -cf ../plane-fork-live.1.tar manifest.json cfg*.json )
IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$(sha256sum "$T/b/plane-fork-live.1.tar" | awk '{print $1}') run -e "$T/env" "$SHA"; expect_fail "one of three images with another label -> FAIL" "bound to the release sha"
# hostile config path inside the manifest
rm -rf "$T/b/x"; mkdir "$T/b/x"; ( cd "$T/b/x" && printf '[{"Config":"../../etc/passwd"},{"Config":"/etc/passwd"},{"Config":"a b"}]' >manifest.json && tar -cf ../plane-fork-live.1.tar manifest.json )
IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$(sha256sum "$T/b/plane-fork-live.1.tar" | awk '{print $1}') run -e "$T/env" "$SHA"; expect_fail "hostile Config paths -> FAIL" "bound to the release sha"
# notes as the binding source (archive without labels)
mktar "$T/b/plane-fork-live.1.tar" NONE; H2=$(sha256sum "$T/b/plane-fork-live.1.tar" | awk '{print $1}')
printf 'SHA verified: %s is in origin/live-updates/v1.4.2\nTar sha256: %s\n' "$SHA" "$H2" >"$T/notes2"
BUILD_NOTES="$T/notes2" IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$H2 run -e "$T/env" "$SHA"; [ "$RC" = 0 ] && ok "SHA verified line naming the sha binds an unlabelled archive" || bad "notes binding rc=$RC"
# notes-only binding needs BOTH the SHA verified line and a matching Tar sha256 line
printf 'SHA verified: %s is in origin/live-updates/v1.4.2\n' "$SHA" >"$T/notes2"
BUILD_NOTES="$T/notes2" IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$H2 run -e "$T/env" "$SHA"; expect_fail "notes-only binding without a Tar sha256 line -> FAIL" "bound to the release sha"
echo "$OUT" | grep -q "no 'Tar sha256:' line" && ok "missing Tar line is named" || bad "missing Tar line message"
printf 'SHA verified: %s is in origin/live-updates/v1.4.2\nTar sha256: %s\n' "$SHA" "$(printf '3%.0s' $(seq 64))" >"$T/notes2"
BUILD_NOTES="$T/notes2" IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$H2 run -e "$T/env" "$SHA"; expect_fail "notes-only binding with a different Tar sha256 -> FAIL" "bound to the release sha"
printf 'SHA verified: %s is in origin/live-updates/v1.4.2\n' "$OTHER" >"$T/notes2"
BUILD_NOTES="$T/notes2" IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$H2 run -e "$T/env" "$SHA"; expect_fail "notes naming a different sha -> FAIL" "bound to the release sha"
printf 'Build ok\n' >"$T/notes2"
BUILD_NOTES="$T/notes2" IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$H2 run -e "$T/env" "$SHA"; expect_fail "notes without a SHA verified line -> FAIL" "bound to the release sha"
printf 'SHA verified: %s is in origin/live-updates/v1.4.2\n' "$OTHER" >"$T/notes2"
mktar "$T/b/plane-fork-live.1.tar" "$SHA"; H3=$(sha256sum "$T/b/plane-fork-live.1.tar" | awk '{print $1}')
BUILD_NOTES="$T/notes2" IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$H3 run -e "$T/env" "$SHA"; expect_fail "good labels but notes name another sha -> FAIL" "bound to the release sha"
printf 'SHA verified: %s is in origin/live-updates/v1.4.2\nTar sha256: %s\n' "$SHA" "$(printf '2%.0s' $(seq 64))" >"$T/notes2"
BUILD_NOTES="$T/notes2" IMAGE_TAR="$T/b/plane-fork-live.1.tar" IMAGE_SHA256=$H3 run -e "$T/env" "$SHA"; expect_fail "IMAGE_SHA256 differs from the notes Tar line -> FAIL" "image archive sha256"
ls "$T"/*.sha256 >/dev/null 2>&1 && bad "gate left files next to the archive" || ok "no files left behind"

# 4 runbook table
RUNBOOK_FILE="$HERE/RUNBOOK.md" run -e "$T/env" "$SHA"; expect_fail "shipped (empty) table -> FAIL" "RUNBOOK inspection"
echo "$OUT" | grep -q 'rows have no result' && ok "reports how many rows are empty" || bad "empty-row message"
awk '/^### Inspection results/{s=1} s&&/^\| Free disk in/{sub(/\| recorded \|$/,"|  |")} {print}' "$T/runbook.filled" >"$T/rb.one"
RUNBOOK_FILE="$T/rb.one" run -e "$T/env" "$SHA"; expect_fail "one empty row -> FAIL" "RUNBOOK inspection"
printf '# nothing\n' >"$T/rb.none"
RUNBOOK_FILE="$T/rb.none" run -e "$T/env" "$SHA"; expect_fail "no table at all -> FAIL" "RUNBOOK inspection"

# 5 settings
for p in "10.0.0.0/8" "192.0.2.1" "2001:db8::/32" "::1" "fd00::1,10.1.2.3/32" "1:2:3:4:5:6:7:8" "10.0.0.0/8 , 172.16.0.0/12" "2001:db8::/16" ; do
  setting LIVE_EVENTS_TRUSTED_PROXIES "$p"; good; [ "$RC" = 0 ] && ok "trusted proxies '$p' valid" || bad "trusted proxies '$p' rc=$RC"
done
for p in "" "," " " "10.0.0.0/33" "10.0.0.0/" "10.0.0.0/0" "300.1.1.1" "10.0.0/8" "not-an-ip" "10.0.0.0/8/8" "2001:db8::/129" "1:2:3:4:5:6:7" "1::2::3" "12345::1" "10.0.0.1,bad" "0.0.0.0/1" "10.0.0.0/1" "0.0.0.0/1,128.0.0.0/1" "10.0.0.0/7" "::/0" "2001::/15" "8000::/1" ":1::2" "1::2:" ":1:2:3:4:5:6:7"; do
  setting LIVE_EVENTS_TRUSTED_PROXIES "$p"; good; expect_fail "trusted proxies '$p' invalid" "LIVE_EVENTS_TRUSTED_PROXIES"
done
setting LIVE_EVENTS_TRUSTED_PROXIES UNSET; good; expect_fail "trusted proxies unset" "LIVE_EVENTS_TRUSTED_PROXIES"
cp "$T/env.base" "$T/env"

setting PAGES_REBASE_MAX_HTML_BYTES 262144; good; [ "$RC" = 0 ] && ok "rebase == api limit passes" || bad "equal limits rc=$RC"
setting PAGES_REBASE_MAX_HTML_BYTES 262143; good; expect_fail "rebase < api limit" "PAGES_REBASE_MAX_HTML_BYTES"
setting PAGES_REBASE_MAX_HTML_BYTES abc; good; expect_fail "rebase not a number" "PAGES_REBASE_MAX_HTML_BYTES"
setting PAGES_REBASE_MAX_HTML_BYTES 0; good; expect_fail "rebase zero" "PAGES_REBASE_MAX_HTML_BYTES"
setting PAGES_REBASE_MAX_HTML_BYTES UNSET; good; [ "$RC" = 0 ] && ok "rebase unset uses the default 524288 and passes" || bad "rebase unset rc=$RC"
setting PAGES_REBASE_MAX_HTML_BYTES UNSET; echo PAGES_API_MAX_HTML_BYTES=600000 >>"$T/env"; sed -i '/^PAGES_API_MAX_HTML_BYTES=262144/d' "$T/env"; good
expect_fail "api limit above the default rebase limit" "PAGES_REBASE_MAX_HTML_BYTES"
cp "$T/env.base" "$T/env"

for m in 64 256 4096; do setting PAGES_REBASE_WORKER_MAX_MB $m; good; [ "$RC" = 0 ] && ok "worker MB $m passes" || bad "worker MB $m rc=$RC"; done
for m in 0 63 4097 abc -1; do setting PAGES_REBASE_WORKER_MAX_MB "$m"; good; expect_fail "worker MB '$m' fails" "PAGES_REBASE_WORKER_MAX_MB"; done
setting PAGES_REBASE_WORKER_MAX_MB UNSET; good; [ "$RC" = 0 ] && ok "worker MB unset passes" || bad "worker MB unset rc=$RC"
cp "$T/env.base" "$T/env"

setting NODE_OPTIONS "--max-old-space-size=2048"; good; expect_fail "NODE_OPTIONS max-old-space-size" "NODE_OPTIONS"
setting NODE_OPTIONS "--trace-warnings --max-old-space-size=2048"; good; expect_fail "NODE_OPTIONS combined" "NODE_OPTIONS"
setting NODE_OPTIONS UNSET; good; [ "$RC" = 0 ] && ok "NODE_OPTIONS unset passes" || bad "NODE_OPTIONS unset rc=$RC"
cp "$T/env.base" "$T/env"

for s in "" "change-this-key-on-deployment" "\"change-this-key-on-deployment\"" "change-this-key-on-deployment " " change-this-key-on-deployment" "change-this-key-on-deployment # note" "  change-this-key-on-deployment   # note" "'change-this-key-on-deployment' # note" "prefix-change-this-key-on-deployment-suffix" "CHANGE-THIS-KEY-ON-DEPLOYMENT" "   " "# only a comment"; do
  setting LIVE_SERVER_SECRET_KEY "$s"; good; expect_fail "secret '$s' fails" "LIVE_SERVER_SECRET_KEY"
done
setting LIVE_SERVER_SECRET_KEY UNSET; good; expect_fail "secret unset fails" "LIVE_SERVER_SECRET_KEY"
setting LIVE_SERVER_SECRET_KEY "\"$SENTINEL\""; good; [ "$RC" = 0 ] && ok "quoted secret passes" || bad "quoted secret rc=$RC"
echo "$OUT" | grep -q "$SENTINEL" && bad "quoted secret printed" || ok "quoted secret not printed"
setting LIVE_SERVER_SECRET_KEY "change-this-key-on-deployment"; good
echo "$OUT" | grep -q 'change-this-key-on-deployment$' && bad "placeholder value echoed" || ok "failing secret check prints no value"
cp "$T/env.base" "$T/env"
# settings from the environment when no env file is given
OUT=$(env -u NODE_OPTIONS LIVE_EVENTS_TRUSTED_PROXIES=10.0.0.0/8 PAGES_REBASE_MAX_HTML_BYTES=524288 PAGES_API_MAX_HTML_BYTES=262144 \
  PAGES_REBASE_WORKER_MAX_MB=512 LIVE_SERVER_SECRET_KEY=$SENTINEL "$GATE" "$SHA" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "settings from the environment: GO" || { bad "environment settings rc=$RC"; echo "$OUT"; }
echo "$OUT" | grep -q "$SENTINEL" && bad "secret leaked (env mode)" || ok "secret not printed (env mode)"
OUT=$(env -u NODE_OPTIONS -u LIVE_SERVER_SECRET_KEY "$GATE" "$SHA" 2>&1); RC=$?
[ "$RC" = 1 ] && ok "environment without settings: NO-GO" || bad "empty environment rc=$RC"

# 6 inspect
STUB_INSPECT_RC=2 run -e "$T/env" "$SHA"; expect_fail "inspect.sh STOP -> FAIL" "inspect.sh preflight"
echo "$OUT" | grep -q 'STOP: stub reason' && ok "inspect STOP line is shown" || bad "inspect STOP not shown"
PLANE_CTID="" run -e "$T/env" "$SHA"; expect_fail "PLANE_CTID unset -> FAIL" "inspect.sh preflight"
PVE_HOST="" PATH="/usr/bin:/bin" run -e "$T/env" "$SHA"; expect_fail "no PVE_HOST and no pct -> FAIL" "inspect.sh preflight"
grep -q 'bash -s' "$STUB_LOG" 2>/dev/null; good; grep -q 'PLANE_CTID=999 PLANE_APP_DIR=/opt/plane-app bash -s' "$STUB_LOG" && ok "inspect.sh is run over ssh like RUNBOOK step 1" || bad "ssh command"

# 6b hostile or hanging inspect inputs are never sent
for v in "101; touch x" '101 $(id)' "10a" "-1" "101 && id"; do
  PLANE_CTID="$v" run -e "$T/env" "$SHA"; expect_fail "PLANE_CTID '$v' refused" "inspect.sh preflight"
  [ ! -s "$STUB_LOG" ] && ok "  and never sent" || bad "hostile PLANE_CTID reached ssh"
done
for v in "relative/dir" "/opt/a;touch x" '/opt/$(id)' "/opt/a b" '/opt/`id`' "/opt/a|b" "/opt/a'b"; do
  PLANE_APP_DIR="$v" run -e "$T/env" "$SHA"; expect_fail "PLANE_APP_DIR '$v' refused" "inspect.sh preflight"
  [ ! -s "$STUB_LOG" ] && ok "  and never sent" || bad "hostile PLANE_APP_DIR reached ssh"
done
for v in "-oProxyCommand=id" "host;id" 'h$(id)' "a b"; do
  PVE_HOST="$v" run -e "$T/env" "$SHA"; expect_fail "PVE_HOST '$v' refused" "inspect.sh preflight"
  [ ! -s "$STUB_LOG" ] && ok "  and never sent" || bad "hostile PVE_HOST reached ssh"
done
good; grep -q -- '-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=' "$STUB_LOG" && grep -q -- ' -- pve.example.test ' "$STUB_LOG" && ok "ssh runs with BatchMode, ConnectTimeout, ServerAlive and --" || bad "ssh options"
start=$SECONDS
STUB_SLEEP=30 GATE_INSPECT_TIMEOUT=2 run -e "$T/env" "$SHA"
[ "$((SECONDS - start))" -lt 20 ] && ok "a hanging ssh is cut off" || bad "gate hung"
expect_fail "hanging ssh -> FAIL, not a hang" "inspect.sh preflight"

# no timeout command: a visible FAIL, inspect.sh is not run unlimited
mkdir -p "$T/nt"
for f in /usr/bin/* /bin/*; do b=${f##*/}; [ "$b" = timeout ] || [ -e "$T/nt/$b" ] || ln -s "$f" "$T/nt/$b" 2>/dev/null; done
PATH="$T/nt:$T/bin" run -e "$T/env" "$SHA"
if PATH="$T/nt" command -v timeout >/dev/null 2>&1; then bad "test setup: timeout still on PATH"; else
  expect_fail "no timeout command -> FAIL" "inspect.sh preflight"
  echo "$OUT" | grep -q 'no timeout command found' && ok "missing timeout is named" || bad "timeout message"
  [ ! -s "$STUB_LOG" ] && ok "  and ssh was not run" || bad "ssh ran without a time limit"
fi

# env-file values as compose reads them (trailing space and comments)
setting PAGES_API_MAX_HTML_BYTES "262144 # api cap"; good; [ "$RC" = 0 ] && ok "numeric value with a trailing comment is read" || bad "numeric comment rc=$RC"
setting PAGES_REBASE_WORKER_MAX_MB "   512"; good; [ "$RC" = 0 ] && ok "numeric value with leading spaces is read" || bad "numeric leading spaces rc=$RC"
setting PAGES_REBASE_WORKER_MAX_MB "512   "; good; [ "$RC" = 0 ] && ok "numeric value with trailing spaces is read" || bad "numeric spaces rc=$RC"
setting NODE_OPTIONS "--trace-warnings # --max-old-space-size=1"; good; [ "$RC" = 0 ] && ok "comment text is not part of NODE_OPTIONS" || bad "NODE_OPTIONS comment rc=$RC"
cp "$T/env.base" "$T/env"
for s in "change-this-key-on-deployment " " change-this-key-on-deployment" "change-this-key-on-deployment # note"; do
  OUT=$(env -u NODE_OPTIONS LIVE_EVENTS_TRUSTED_PROXIES=10.0.0.0/8 LIVE_SERVER_SECRET_KEY="$s" "$GATE" "$SHA" 2>&1); RC=$?
  [ "$RC" = 1 ] && echo "$OUT" | grep -q '^FAIL LIVE_SERVER_SECRET_KEY' && ok "environment placeholder form '$s' fails" || bad "env placeholder form '$s' rc=$RC"
done

# 7 rollback
sed 's/LIVE_EVENTS_ENABLED: "1"/LIVE_EVENTS_ENABLED: "0"/' "$HERE/docker-compose.override.yaml" >"$T/ov"
OVERRIDE_FILE="$T/ov" run -e "$T/env" "$SHA"; expect_fail "L1 flag lines missing -> FAIL" "rollback L1"
OVERRIDE_FILE="$T/none" run -e "$T/env" "$SHA"; expect_fail "override missing -> FAIL" "rollback L1"
STOCK_RELEASE="" run -e "$T/env" "$SHA"; expect_fail "STOCK_RELEASE unset -> FAIL" "rollback L2"
STOCK_RELEASE="v1.4.2-live.3" run -e "$T/env" "$SHA"; expect_fail "STOCK_RELEASE is a fork tag -> FAIL" "rollback L2"
STOCK_RELEASE='v1;rm' run -e "$T/env" "$SHA"; expect_fail "STOCK_RELEASE bad characters -> FAIL" "rollback L2"

# summary lists every failing item and nothing is written into the repo
STOCK_RELEASE="" QA_RECORD="$T/none" run -e "$T/env" "$SHA"
[ "$(echo "$OUT" | grep -c '^  - ')" = 2 ] && ok "NO-GO lists each failing item" || bad "failing list"
[ -z "$(git -C "$T/work" status --porcelain --untracked-files=all | grep -v '^?? ' )" ] && ok "repo checkout not modified" || bad "repo modified"

if grep -nE '(^|[^A-Za-z_-])(rm -rf? [^"$]|pkill|kill|docker (rm|stop|restart|kill|exec|compose)|pct (stop|start|snapshot|rollback|destroy))' "$HERE/gate.sh" | grep -v '^[0-9]*:#'; then
  bad "gate.sh contains a mutating command"
else ok "no mutating commands in gate.sh"; fi

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
