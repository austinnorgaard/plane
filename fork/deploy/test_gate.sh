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
if [ "${STUB_INSPECT_RC:-0}" = 0 ]; then echo "RESULT: no STOP lines"; else echo "STOP: stub reason"; echo "RESULT: 1 STOP line(s); do not deploy, escalate"; fi
exit "${STUB_INSPECT_RC:-0}"
STUB
chmod +x "$T/bin/ssh"
export GIT_TERMINAL_PROMPT=0 STUB_LOG="$T/log" PATH="$T/bin:$PATH"

# --- inputs
SENTINEL="SENTINEL-not-a-real-secret-4711"
printf 'QA: PASS @ %s\n' "${SHA:0:12}" >"$T/qa"
printf 'tar-content' >"$T/plane-fork-live.1.tar"
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
run -e "$T/env" "$NEW"
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
printf 'Build ok\nTar sha256: %s\n' "$TARSHA" >"$T/notes"
IMAGE_SHA256="" BUILD_NOTES="$T/notes" run -e "$T/env" "$SHA"; [ "$RC" = 0 ] && ok "sha from BUILD_NOTES line passes" || bad "BUILD_NOTES rc=$RC"
printf 'Tar sha256: %s\n' "$(printf '1%.0s' $(seq 64))" >"$T/notes"
IMAGE_SHA256="" BUILD_NOTES="$T/notes" run -e "$T/env" "$SHA"; expect_fail "BUILD_NOTES with another sha -> FAIL" "image archive sha256"
ls "$T"/*.sha256 >/dev/null 2>&1 && bad "gate left files next to the archive" || ok "no files left behind"

# 4 runbook table
RUNBOOK_FILE="$HERE/RUNBOOK.md" run -e "$T/env" "$SHA"; expect_fail "shipped (empty) table -> FAIL" "RUNBOOK inspection"
echo "$OUT" | grep -q 'rows have no result' && ok "reports how many rows are empty" || bad "empty-row message"
awk '/^### Inspection results/{s=1} s&&/^\| Free disk in/{sub(/\| recorded \|$/,"|  |")} {print}' "$T/runbook.filled" >"$T/rb.one"
RUNBOOK_FILE="$T/rb.one" run -e "$T/env" "$SHA"; expect_fail "one empty row -> FAIL" "RUNBOOK inspection"
printf '# nothing\n' >"$T/rb.none"
RUNBOOK_FILE="$T/rb.none" run -e "$T/env" "$SHA"; expect_fail "no table at all -> FAIL" "RUNBOOK inspection"

# 5 settings
for p in "10.0.0.0/8" "192.0.2.1" "2001:db8::/32" "::1" "fd00::1,10.1.2.3/32" "1:2:3:4:5:6:7:8"; do
  setting LIVE_EVENTS_TRUSTED_PROXIES "$p"; good; [ "$RC" = 0 ] && ok "trusted proxies '$p' valid" || bad "trusted proxies '$p' rc=$RC"
done
for p in "" "," " " "10.0.0.0/33" "10.0.0.0/" "10.0.0.0/0" "300.1.1.1" "10.0.0/8" "not-an-ip" "10.0.0.0/8/8" "2001:db8::/129" "1:2:3:4:5:6:7" "1::2::3" "12345::1" "10.0.0.1,bad"; do
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

for s in "" "change-this-key-on-deployment" "\"change-this-key-on-deployment\""; do
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
