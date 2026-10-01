#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# test_upgrade_rollback.sh - offline tests for fork/test/upgrade-rollback.sh (argument handling
# and the fingerprint comparison). podman, docker, docker-compose, podman-compose and curl are
# replaced by stubs that come first on PATH, so no engine or stack is needed.
# Usage: fork/test/test_upgrade_rollback.sh        (exit 0 = all tests passed)
# shellcheck disable=SC2015 # "cond && check 0 || check 1": check never fails
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/upgrade-rollback.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0
PASSES=0

unset CONTAINER_ENGINE COMPOSE_CMD COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES \
  DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG CONTAINER_HOST FORK_N UPGRADE_ROLLBACK_REPORT
for v in $(compgen -v | grep -E '^(STUB_|LOCAL_STACK_)'); do unset "$v"; done
export LOCAL_STACK_PROJECT="plane-lu-test-$$"
export LOCAL_STACK_DIR=$T/d
mkdir -p "$LOCAL_STACK_DIR" "$T/bin"

check() { # check NAME EXIT_CODE
  if [ "$2" -eq 0 ]; then
    PASSES=$((PASSES + 1))
    echo "ok   $1"
  else
    FAILS=$((FAILS + 1))
    echo "FAIL $1"
  fi
}
has() { grep -q -- "$2" "$1"; }

# every engine stub logs its call; `image exists` and `image inspect` answer by STUB_MISSING_IMAGE
for name in podman docker docker-compose podman-compose curl; do
  cat >"$T/bin/$name" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$STUB_DIR/engine.log"
case "$*" in
  "compose version"*) exit 0 ;;
  "image exists "* | "image inspect "*) [ -z "${STUB_MISSING_IMAGE:-}" ]; exit $? ;;
esac
exit 1
STUB
  chmod +x "$T/bin/$name"
done
export STUB_DIR=$T
export PATH="$T/bin:$PATH"
hash -r
: >"$T/engine.log"

# ------------------------------------------------------------------ argument handling
"$SCRIPT" help >"$T/help.out" 2>&1
check "help exits 0" $?
has "$T/help.out" 'upgrade-rollback.sh run' && check "help lists the run subcommand" 0 || check "help lists the run subcommand" 1
has "$T/help.out" 'compare' && check "help lists the compare subcommand" 0 || check "help lists the compare subcommand" 1

"$SCRIPT" >"$T/none.out" 2>&1
check "no argument prints the usage and exits 0" $?
"$SCRIPT" frobnicate >"$T/bad.out" 2>&1
check "unknown subcommand exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
has "$T/bad.out" 'upgrade-rollback.sh run' && check "unknown subcommand prints the usage" 0 || check "unknown subcommand prints the usage" 1

: >"$T/engine.log"
"$SCRIPT" run --bogus >"$T/opt.out" 2>&1
check "run with an unknown option exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
has "$T/opt.out" 'unknown option --bogus' && check "run names the unknown option" 0 || check "run names the unknown option" 1
check "run with an unknown option touches no engine" "$([ ! -s "$T/engine.log" ] && echo 0 || echo 1)"

STUB_MISSING_IMAGE=1 "$SCRIPT" run >"$T/img.out" 2>&1
check "run exits 2 when an image is missing" "$([ $? -eq 2 ] && echo 0 || echo 1)"
has "$T/img.out" 'missing stock image makeplane/plane-backend:v1.4.2' && check "run names the missing stock image" 0 || check "run names the missing stock image" 1
has "$T/img.out" 'plane-fork-api:v1.4.2-live.2' && check "run defaults to fork build 2" 0 || check "run defaults to fork build 2" 1
FORK_N=7 STUB_MISSING_IMAGE=1 "$SCRIPT" run >"$T/img7.out" 2>&1
has "$T/img7.out" 'plane-fork-api:v1.4.2-live.7' && check "FORK_N selects the fork build" 0 || check "FORK_N selects the fork build" 1
check "a missing image stops before any stack is started" "$(! grep -qE ' (up|run) ' "$T/engine.log" && echo 0 || echo 1)"

"$SCRIPT" compare >"$T/cmp0.out" 2>&1
check "compare without files exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"
"$SCRIPT" compare "$T/none-a.json" "$T/none-b.json" >"$T/cmp1.out" 2>&1
check "compare with a missing file exits 2" "$([ $? -eq 2 ] && echo 0 || echo 1)"

# ------------------------------------------------------------------ fingerprint comparison
mkfp() { # mkfp FILE  (reads python dict literal from stdin)
  python3 -c 'import json,sys;print(json.dumps(eval(sys.stdin.read())))' >"$1"
}
mkfp "$T/base.json" <<'PY'
{"counts": {"issues": 3, "pages": 2, "issue_activities": 9},
 "rows": {"issue:1": {"_name": "first", "name": "aa", "description_html": "bb"},
          "issue:2": {"_name": "second", "name": "cc", "description_html": "dd"},
          "page:1": {"_name": "pg", "description_html": "x1", "description_binary": "null"}},
 "dup_sequence_ids": 0}
PY
"$SCRIPT" compare "$T/base.json" "$T/base.json" >"$T/same.out" 2>&1
check "compare: identical fingerprints exit 0" $?

mkfp "$T/grown.json" <<'PY'
{"counts": {"issues": 4, "pages": 2, "issue_activities": 12},
 "rows": {"issue:1": {"_name": "first", "name": "aa", "description_html": "bb"},
          "issue:2": {"_name": "second", "name": "cc", "description_html": "dd"},
          "issue:3": {"_name": "third", "name": "ee", "description_html": "ff"},
          "page:1": {"_name": "pg", "description_html": "x1", "description_binary": "null"}},
 "dup_sequence_ids": 0}
PY
"$SCRIPT" compare "$T/base.json" "$T/grown.json" >"$T/grown.out" 2>&1
check "compare: new rows and growing tables are fine" $?

mkfp "$T/lost.json" <<'PY'
{"counts": {"issues": 2, "pages": 2, "issue_activities": 9},
 "rows": {"issue:1": {"_name": "first", "name": "aa", "description_html": "bb"},
          "page:1": {"_name": "pg", "description_html": "x1", "description_binary": "null"}},
 "dup_sequence_ids": 0}
PY
"$SCRIPT" compare "$T/base.json" "$T/lost.json" >"$T/lost.out" 2>&1
check "compare: a vanished row exits 1" "$([ $? -eq 1 ] && echo 0 || echo 1)"
has "$T/lost.out" "LOSS issue:2 'second' is missing" && check "compare: names the lost row" 0 || check "compare: names the lost row" 1
has "$T/lost.out" 'LOSS table issues: 3 -> 2 rows' && check "compare: names the shrunk table" 0 || check "compare: names the shrunk table" 1

mkfp "$T/corrupt.json" <<'PY'
{"counts": {"issues": 3, "pages": 2, "issue_activities": 9},
 "rows": {"issue:1": {"_name": "first", "name": "aa", "description_html": "CHANGED"},
          "issue:2": {"_name": "second", "name": "cc", "description_html": "dd"},
          "page:1": {"_name": "pg", "description_html": "x1", "description_binary": "null"}},
 "dup_sequence_ids": 0}
PY
"$SCRIPT" compare "$T/base.json" "$T/corrupt.json" >"$T/corrupt.out" 2>&1
check "compare: a changed field exits 1" "$([ $? -eq 1 ] && echo 0 || echo 1)"
has "$T/corrupt.out" "CORRUPT issue:1 'first' field description_html: bb -> CHANGED" && check "compare: names the row and the field" 0 || check "compare: names the row and the field" 1

mkfp "$T/patched.json" <<'PY'
{"counts": {"issues": 3, "pages": 2, "issue_activities": 9},
 "rows": {"issue:1": {"_name": "first", "name": "aa", "description_html": "bb"},
          "issue:2": {"_name": "second", "name": "cc", "description_html": "dd"},
          "page:1": {"_name": "pg", "description_html": "x2", "description_binary": "b:4:abcd"}},
 "dup_sequence_ids": 0}
PY
"$SCRIPT" compare "$T/base.json" "$T/patched.json" page:1 >"$T/allow.out" 2>&1
check "compare: an allowed row may change" $?
"$SCRIPT" compare "$T/base.json" "$T/patched.json" >"$T/noallow.out" 2>&1
check "compare: the same change without the allowance exits 1" "$([ $? -eq 1 ] && echo 0 || echo 1)"
"$SCRIPT" compare "$T/base.json" "$T/base.json" page:1 >"$T/unchanged.out" 2>&1
check "compare: an allowed row that did not change is a test error" "$([ $? -eq 1 ] && echo 0 || echo 1)"
has "$T/unchanged.out" 'TEST ERROR row page:1 was expected to change' && check "compare: reports the test error" 0 || check "compare: reports the test error" 1
"$SCRIPT" compare "$T/base.json" "$T/lost.json" page:1 issue:2 >"$T/allowlost.out" 2>&1
check "compare: an allowance never excuses a vanished row" "$([ $? -eq 1 ] && echo 0 || echo 1)"

mkfp "$T/dups.json" <<'PY'
{"counts": {"issues": 3, "pages": 2, "issue_activities": 9},
 "rows": {"issue:1": {"_name": "first", "name": "aa", "description_html": "bb"},
          "issue:2": {"_name": "second", "name": "cc", "description_html": "dd"},
          "page:1": {"_name": "pg", "description_html": "x1", "description_binary": "null"}},
 "dup_sequence_ids": 2}
PY
"$SCRIPT" compare "$T/base.json" "$T/dups.json" >"$T/dups.out" 2>&1
check "compare: duplicate sequence ids exit 1" "$([ $? -eq 1 ] && echo 0 || echo 1)"
has "$T/dups.out" '2 duplicate (project, sequence_id) pairs' && check "compare: names the duplicate count" 0 || check "compare: names the duplicate count" 1

# ------------------------------------------------------------------ hygiene
LC_ALL=C.UTF-8 grep -qP '[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{FEFF}\x{00AD}]' "$SCRIPT" "$0"
# grep exits 1 for "no match" and 2 for an error such as an unusable locale; only 1 is a pass
check "no invisible Unicode in the script and its test" "$([ $? -eq 1 ] && echo 0 || echo 1)"
grep -qE 'upgrade-fp|upgrade-rollback.report' "$HERE/../../.gitignore" && check "generated fingerprint directory and report are gitignored" 0 || check "generated fingerprint directory and report are gitignored" 1

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
