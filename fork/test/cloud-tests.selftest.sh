#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# cloud-tests.selftest.sh - stub-based check of the argument parsing and failure exit codes of
# cloud-node-tests.sh and cloud-api-tests.sh. Needs no node, pnpm, database or network:
# corepack is replaced by a stub that installs a fake pnpm.
#   fork/test/cloud-tests.selftest.sh
# shellcheck disable=SC2317  # check() calls after the sourced script are reachable
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected '$2', got '$3')"; fails=$((fails + 1)); fi
}

# fake tree: package.json with a pinned pnpm, and the live-events runner
mkdir -p "$T/src/fork/test/live-events" "$T/bin"
echo '{"packageManager": "pnpm@9.9.9+sha512.abc"}' >"$T/src/package.json"
printf '#!/bin/sh\necho "# pass 3"\necho "# fail 0"\n' >"$T/src/fork/test/live-events/run.sh"

# stub corepack: "corepack enable --install-directory DIR pnpm" writes a fake pnpm into DIR.
# The fake pnpm prints the pinned version, fails when STUB_FAIL contains its arguments, else prints a vitest line.
cat >"$T/bin/corepack" <<'S'
#!/bin/sh
[ "$1" = enable ] || exit 1
dir=$3
cat >"$dir/pnpm" <<'P'
#!/bin/sh
[ "$1" = --version ] && { echo "${STUB_PNPM_VERSION:-9.9.9}"; exit 0; }
echo "pnpm $*" >>"$STUB_CALLS"
case "$*" in *"$STUB_FAIL"*) [ -n "${STUB_FAIL:-}" ] && exit 7 ;; esac
echo "      Tests  5 passed (5)"
P
chmod +x "$dir/pnpm"
S
chmod +x "$T/bin/corepack"

summary() { sed -n '/^==== summary/,$p' "$T/log"; }
run_node() { PATH="$T/bin:$PATH" PLANE_SRC="$T/src" OUT_DIR="$T/out" STUB_CALLS="$T/calls" "$DIR/cloud-node-tests.sh" "$@" >"$T/log" 2>&1; echo $?; }

: >"$T/calls"
check "node all passes" 0 "$(STUB_FAIL='' run_node all)"
check "node all runs install, build-libs and 4 checks" 6 "$(grep -c '^pnpm' "$T/calls")"
check "node summary has 7 step lines" 7 "$(summary | grep -c '^CLOUDNODE step=')"
check "node live-test result captured" 1 "$(summary | grep -c 'step=live-test rc=0.*Tests 5 passed')"
check "node live-events result captured" 1 "$(summary | grep -c 'step=live-events rc=0 wall_s=[0-9]* # pass 3 # fail 0')"
check "node default step is all" 0 "$(STUB_FAIL='' run_node)"
check "node failing step exits with its code" 7 "$(STUB_FAIL='--filter web check:types' run_node all)"
check "node failing step still runs the later steps" 1 "$(summary | grep -c 'step=web-lint')"
check "node failing step is reported rc=7" 1 "$(summary | grep -c 'step=web-types rc=7')"
check "node failed install stops the run" 7 "$(STUB_FAIL='install' run_node all)"
check "node failed install runs nothing after it" 1 "$(summary | grep -c '^CLOUDNODE step=')"
check "node unknown step exits 2" 2 "$(STUB_FAIL='' run_node nope)"
check "node pnpm version mismatch exits 2" 2 "$(STUB_PNPM_VERSION=1.0.0 STUB_FAIL='' run_node live-test)"
check "node two steps" 0 "$(STUB_FAIL='' run_node live-test live-types)"

# api argument parsing (sourcing defines parse_args only)
# shellcheck disable=SC1091
. "$DIR/cloud-api-tests.sh"
parse_args; check "api default services" apt "$SERVICES"
check "api default pytest paths" "plane/tests/unit plane/tests/contract" "${PYTEST_ARGS[*]}"
parse_args --services docker; check "api --services docker" docker "$SERVICES"
parse_args --services=external --keep; check "api --services=external" external "$SERVICES"; check "api --keep" 1 "$KEEP"
parse_args --services apt plane/tests/unit -k slug; check "api extra args replace defaults" "plane/tests/unit -k slug" "${PYTEST_ARGS[*]}"
parse_args --services apt -- -m unit; check "api -- ends options" "-m unit" "${PYTEST_ARGS[*]}"
PLANE_TEST_SERVICES=external parse_args; check "api env default" external "$SERVICES"
parse_args --services bogus 2>/dev/null; check "api bad services rc" 2 "$?"
parse_args --services 2>/dev/null; check "api missing value rc" 2 "$?"
"$DIR/cloud-api-tests.sh" --services bogus >/dev/null 2>&1; check "api script bad services exits 2" 2 "$?"
PLANE_SRC="$T/none" "$DIR/cloud-api-tests.sh" --services external >/dev/null 2>&1; check "api missing tree exits 2" 2 "$?"

echo "selftest failures: $fails"
[ "$fails" -eq 0 ]
