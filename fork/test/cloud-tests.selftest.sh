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
check "node sh without a command exits 2" 2 "$(STUB_FAIL='' run_node sh)"
check "node sh with an empty command exits 2" 2 "$(STUB_FAIL='' run_node sh '')"
check "node sh usage message" 1 "$(grep -c '^usage: cloud-node-tests.sh sh' "$T/log")"
check "node sh with a command runs it" 0 "$(STUB_FAIL='' run_node sh 'true')"
check "node two steps" 0 "$(STUB_FAIL='' run_node live-test live-types)"

# workspace libraries: live-test, live-types and web-types refuse to run (exit 2) until the built outputs exist.
# Stub tree: apps live and web depending on three packages; the editor also exports ./lib.
mkdir -p "$T/libsrc/fork/test/live-events" "$T/libsrc/apps/live" "$T/libsrc/apps/web" "$T/libsrc/packages/logger" "$T/libsrc/packages/editor" "$T/libsrc/packages/ui"
cp "$T/src/package.json" "$T/libsrc/package.json"
cp "$T/src/fork/test/live-events/run.sh" "$T/libsrc/fork/test/live-events/run.sh"
printf '{\n  "dependencies": {\n    "@plane/logger": "workspace:*",\n    "@plane/editor": "workspace:*"\n  },\n  "devDependencies": {\n    "@plane/typescript-config": "workspace:*"\n  }\n}\n' >"$T/libsrc/apps/live/package.json"
printf '{\n  "dependencies": {\n    "@plane/ui": "workspace:*"\n  }\n}\n' >"$T/libsrc/apps/web/package.json"
printf '{"name": "@plane/logger", "main": "./dist/index.mjs"}\n' >"$T/libsrc/packages/logger/package.json"
printf '{\n  "name": "@plane/editor",\n  "main": "./dist/index.js",\n  "exports": {\n    ".": "./dist/index.js",\n    "./lib": "./dist/lib.js"\n  }\n}\n' >"$T/libsrc/packages/editor/package.json"
printf '{"name": "@plane/ui", "exports": {".": "./dist/index.js"}}\n' >"$T/libsrc/packages/ui/package.json"
run_libs() { PATH="$T/bin:$PATH" PLANE_SRC="$T/libsrc" OUT_DIR="$T/out" STUB_CALLS="$T/calls" STUB_FAIL='' "$DIR/cloud-node-tests.sh" "$@" >"$T/log" 2>&1; echo $?; }
MSG='workspace libraries are not built; run: cloud-node-tests.sh install build-libs'
: >"$T/calls"
check "node live-test with unbuilt libraries exits 2" 2 "$(run_libs live-test)"
check "node unbuilt libraries: message printed" 1 "$(grep -c -x "$MSG" "$T/log")"
check "node unbuilt libraries: missing outputs named" 2 "$(grep -c -E '^  packages/(logger: \./dist/index\.mjs|editor: \./dist/index\.js)$' "$T/log")"
check "node unbuilt libraries: the editor ./lib output is checked too" 1 "$(grep -c '^  packages/editor: ./dist/lib.js$' "$T/log")"
check "node unbuilt libraries: pnpm was not run" 0 "$(grep -c '^pnpm' "$T/calls")"
check "node unbuilt libraries: summary line has rc=2" 1 "$(summary | grep -c 'step=live-test rc=2')"
check "node live-types with unbuilt libraries exits 2" 2 "$(run_libs live-types)"
check "node web-types with unbuilt libraries exits 2" 2 "$(run_libs web-types)"
check "node web-types message printed" 1 "$(grep -c -x "$MSG" "$T/log")"
mkdir -p "$T/libsrc/packages/logger/dist" "$T/libsrc/packages/editor/dist"
touch "$T/libsrc/packages/logger/dist/index.mjs" "$T/libsrc/packages/editor/dist/index.js"
check "node only the editor ./lib missing: still exits 2" 2 "$(run_libs live-test)"
check "node only the editor ./lib missing: names it" 1 "$(grep -c '^  packages/editor: ./dist/lib.js$' "$T/log")"
touch "$T/libsrc/packages/editor/dist/lib.js"
check "node live-test with built libraries runs" 0 "$(run_libs live-test)"
check "node built libraries: pnpm ran" 1 "$(grep -c '^pnpm --filter live test' "$T/calls")"
check "node web-types still refused while the ui output is missing" 2 "$(run_libs web-types)"
check "node a library step does not stop other steps (unbuilt, then live-events)" 2 "$(rm -f "$T/libsrc/packages/logger/dist/index.mjs"; run_libs live-test live-events)"
check "node ...and live-events still ran" 1 "$(summary | grep -c 'step=live-events rc=0')"

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

# api: pytest exit code. A stub venv whose python fails pytest with rc 1 (PLANE_TEST_SKIP_SETUP skips services and pip).
mkdir -p "$T/apisrc/apps/api/plane" "$T/venv/bin"
cat >"$T/venv/bin/python" <<'S'
#!/bin/sh
[ "$1" = -c ] && exit 0
echo "FAILED plane/tests/unit/test_stub.py::test_stub"
echo "========== 1 failed, 2 passed in 0.10s =========="
exit "${STUB_PYTEST_RC:-1}"
S
chmod +x "$T/venv/bin/python"
run_api() { PLANE_TEST_SKIP_SETUP=1 PLANE_SRC="$T/apisrc" PLANE_VENV="$T/venv" OUT_DIR="$T/apiout" "$DIR/cloud-api-tests.sh" "$@" >"$T/apilog" 2>&1; echo $?; }
check "api pytest rc 1 is the script exit code" 1 "$(run_api plane/tests/unit)"
check "api reports pytest_rc=1" 1 "$(grep -c 'pytest_rc=1' "$T/apilog")"
check "api lists the failing test id (output and summary)" 2 "$(grep -c '^FAILED plane/tests/unit/test_stub.py' "$T/apilog")"
check "api PLANE_TEST_SKIP_SETUP=1 is logged" 1 "$(run_api >/dev/null; grep -c 'PLANE_TEST_SKIP_SETUP=1: skipping service start and venv setup' "$T/apilog")"
check "api pytest rc 4 is passed through" 4 "$(STUB_PYTEST_RC=4 run_api)"
check "api pytest rc 0 exits 0" 0 "$(STUB_PYTEST_RC=0 run_api)"
check "api apt refuses a non-loopback DB_HOST" 2 "$(DB_HOST=db.example.invalid run_api --services apt)"
check "api apt refusal message" 1 "$(grep -c 'not a loopback address' "$T/apilog")"
check "api docker refuses a non-loopback MQ_HOST" 2 "$(MQ_HOST=10.0.0.5 run_api --services docker)"
check "api apt rejects a quote in DB_PASS" 2 "$(DB_PASS="x'y" run_api --services apt)"
check "api apt refuses 127.evil.example.com (glob injection)" 2 "$(DB_HOST=127.evil.example.com run_api --services apt)"
check "api apt accepts 127.0.0.1" 1 "$(DB_HOST=127.0.0.1 run_api --services apt)"
check "api apt refuses @ in DB_PASS" 2 "$(DB_PASS="x@y" run_api --services apt)"
check "api apt refuses @ in MQ_PASS" 2 "$(MQ_PASS="x@y" run_api --services apt)"
check "api apt refuses @ in DB_USER" 2 "$(DB_USER="x@y" run_api --services apt)"
check "api apt refuses @ in MQ_USER" 2 "$(MQ_USER="x@y" run_api --services apt)"
check "api apt refuses @ in MQ_VHOST" 2 "$(MQ_VHOST="x@y" run_api --services apt)"
check "api apt @ refusal message names the variable" 1 "$(grep -c 'MQ_VHOST' "$T/apilog")"
check "api apt accepts localhost" 1 "$(DB_HOST=localhost REDIS_HOST=localhost MQ_HOST=localhost run_api --services apt)"
check "api apt accepts ::1" 1 "$(DB_HOST=::1 REDIS_HOST=::1 MQ_HOST=::1 run_api --services apt)"
check "api apt refuses - in DB_NAME" 2 "$(DB_NAME="plane-test" run_api --services apt)"
check "api external allows other hosts" 1 "$(DB_HOST=db.example.invalid run_api --services external)"

echo "selftest failures: $fails"
[ "$fails" -eq 0 ]
