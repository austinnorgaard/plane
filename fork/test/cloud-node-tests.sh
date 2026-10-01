#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# cloud-node-tests.sh - the node checks of node-tests.sh, run natively (no podman, no containers).
#
# Same step names and selection as node-tests.sh. Requirements: node 22.18 or newer and corepack
# (ships with node). pnpm is NOT installed globally: corepack provides the version pinned in the
# root package.json "packageManager" field, through a shim directory that is put on PATH so that
# turbo's child processes find the same pnpm.
#
# Usage (from anywhere):
#   fork/test/cloud-node-tests.sh                 # same as "all"
#   fork/test/cloud-node-tests.sh all             # every step below, in order, never stops early except after a failed install
#   fork/test/cloud-node-tests.sh install         # pnpm install --frozen-lockfile
#   fork/test/cloud-node-tests.sh build-libs      # turbo build of the workspace packages live and web depend on
#   fork/test/cloud-node-tests.sh live-test       # pnpm --filter live test          (vitest)
#   fork/test/cloud-node-tests.sh live-types      # pnpm --filter live check:types
#   fork/test/cloud-node-tests.sh web-types       # pnpm --filter web check:types
#   fork/test/cloud-node-tests.sh web-lint        # pnpm --filter web check:lint
#   fork/test/cloud-node-tests.sh live-events     # sh fork/test/live-events/run.sh (node built-in runner, no install needed)
#   fork/test/cloud-node-tests.sh sh 'any shell cmd'
#   fork/test/cloud-node-tests.sh live-test live-types   # several steps in one call
#
# Environment overrides:
#   PLANE_SRC      tree under test (default: the repository this script lives in)
#   OUT_DIR        where node-<step>.log files go (default: ${TMPDIR:-/tmp}/plane-cloud-tests)
#   NODE_HEAP_MB   node heap cap (default 4096)
#
# Each step prints "CLOUDNODE step=<name> rc=<code> wall_s=<n> <result>". After the last step a
# table of those lines is repeated. The exit code is 0 only if every step passed; otherwise it
# is the first non-zero step code. Unknown step: exit 2.
#
# live-test, live-types and web-types need the built outputs of the workspace packages their app
# depends on. If one is missing the step is not run: it prints "workspace libraries are not built;
# run: cloud-node-tests.sh install build-libs" and the exit code is 2 (not 1, which means a test failed).
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${PLANE_SRC:-$(cd "$SELF_DIR/../.." && pwd)}
OUT_DIR=${OUT_DIR:-${TMPDIR:-/tmp}/plane-cloud-tests}
NODE_HEAP_MB=${NODE_HEAP_MB:-4096}
ALL_STEPS=(install build-libs live-test live-types web-types web-lint live-events)

export CI=true COREPACK_ENABLE_DOWNLOAD_PROMPT=0 TURBO_TELEMETRY_DISABLED=1 NEXT_TELEMETRY_DISABLED=1
export NODE_OPTIONS="--max-old-space-size=$NODE_HEAP_MB"

[ -f "$SRC/package.json" ] || { echo "no package.json under PLANE_SRC=$SRC" >&2; exit 2; }
mkdir -p "$OUT_DIR"
cd "$SRC" || exit 2

SUMMARY=()

# Put a pnpm shim (from corepack, at the packageManager version) first on PATH.
setup_pnpm() {
  command -v corepack >/dev/null 2>&1 || { echo "corepack not found (install node 22 or newer)" >&2; return 2; }
  local shim="$OUT_DIR/bin"
  mkdir -p "$shim"
  corepack enable --install-directory "$shim" pnpm || return 2
  export PATH="$shim:$PATH"
  local want have
  want=$(sed -n 's/.*"packageManager": *"pnpm@\([0-9][0-9.]*\).*/\1/p' package.json | head -1)
  have=$(pnpm --version 2>/dev/null | tail -1)
  echo "pnpm pinned=$want active=$have"
  if [ -n "$want" ] && [ "$want" != "$have" ]; then
    echo "pnpm version mismatch (pinned $want, active $have)" >&2
    return 2
  fi
}

# Pull a short result out of a step log (best effort, never fails the step).
result_of() {
  local name=$1 log=$2
  case "$name" in
    live-test)   grep -aE '^ *Tests +[0-9]' "$log" | tail -1 | sed 's/^ *//' ;;
    live-events) { grep -aE '^# (pass|fail) ' "$log" | tr '\n' ' '; } ;;
    web-lint)    grep -aE '^Found [0-9]+ warnings' "$log" | tail -1 ;;
    *) ;;
  esac
}

# Built entry points that the workspace dependencies of an app must have (apps/<app>/package.json).
# For each "@plane/<x>": "workspace:*" dependency (config-only *-config packages are skipped) the
# package's main file, or else its first ./dist export, must exist, and so must a "./lib" export target.
missing_libs() { # app -> prints one "<package dir>: <missing file>" line per missing output
  local app=$1 dep dir rel
  [ -f "apps/$app/package.json" ] || return 0
  while IFS= read -r dep; do
    dir="packages/${dep#@plane/}"
    [ -f "$dir/package.json" ] || continue
    rel=$(sed -n 's/^ *"main": *"\([^"]*\)".*/\1/p' "$dir/package.json" | head -1)
    [ -n "$rel" ] || rel=$(grep -o '"\./dist/[^"]*"' "$dir/package.json" | head -1 | tr -d '"')
    [ -z "$rel" ] || [ -e "$dir/$rel" ] || echo "$dir: $rel"
    rel=$(sed -n 's/^ *"\.\/lib": *"\([^"]*\)".*/\1/p' "$dir/package.json" | head -1)
    [ -z "$rel" ] || [ -e "$dir/$rel" ] || echo "$dir: $rel"
  done < <(sed -n 's/^ *"\(@plane\/[a-z0-9-]*\)": *"workspace:.*/\1/p' "apps/$app/package.json" | grep -v -- '-config$')
}

# Refuse to run a step whose workspace libraries are not built (exit code 2, a setup problem).
need_libs() { # step app
  local miss
  miss=$(missing_libs "$2")
  [ -z "$miss" ] && return 0
  {
    echo "workspace libraries are not built; run: cloud-node-tests.sh install build-libs"
    echo "missing build outputs:"
    while IFS= read -r line; do echo "  $line"; done <<<"$miss"
  } >&2
  SUMMARY+=("CLOUDNODE step=$1 rc=2 wall_s=0 workspace libraries are not built")
  return 2
}

run_step() { # name cmd...
  local name=$1 start rc log res
  shift
  log="$OUT_DIR/node-$name.log"
  start=$(date +%s)
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  res=$(result_of "$name" "$log" | tr -s ' ' | sed 's/ *$//')
  local line="CLOUDNODE step=$name rc=$rc wall_s=$(( $(date +%s) - start ))${res:+ $res}"
  echo "$line"
  SUMMARY+=("$line")
  return "$rc"
}

step() {
  case "$1" in
    install)     run_step install    pnpm install --frozen-lockfile ;;
    build-libs)  run_step build-libs pnpm turbo run build --filter='live^...' --filter='web^...' ;;
    live-test)   need_libs live-test live && run_step live-test  pnpm --filter live test ;;
    live-types)  need_libs live-types live && run_step live-types pnpm --filter live check:types ;;
    web-types)   need_libs web-types web && run_step web-types  pnpm --filter web check:types ;;
    web-lint)    run_step web-lint   pnpm --filter web check:lint ;;
    live-events) run_step live-events sh fork/test/live-events/run.sh ;;
    sh)          run_step adhoc      bash -c "${2:?usage: cloud-node-tests.sh sh 'command'}" ;;
    *) echo "unknown step: $1 (steps: ${ALL_STEPS[*]} all sh)" >&2; return 2 ;;
  esac
}

finish() {
  local rc=$1
  if [ "${#SUMMARY[@]}" -gt 0 ]; then
    echo "==== summary ===="
    printf '%s\n' "${SUMMARY[@]}"
  fi
  exit "$rc"
}

[ "$#" -eq 0 ] && set -- all

# validate step names before doing any work
args=("$@")
for ((n = 0; n < ${#args[@]}; n++)); do
  case "${args[n]}" in
    all|install|build-libs|live-test|live-types|web-types|web-lint|live-events) ;;
    sh) [ -n "${args[n + 1]:-}" ] || { echo "usage: cloud-node-tests.sh sh 'command'" >&2; exit 2; }
        break ;;
    *) echo "unknown step: ${args[n]} (steps: ${ALL_STEPS[*]} all sh)" >&2; exit 2 ;;
  esac
done

setup_pnpm || exit 2

first_rc=0
note() { [ "$first_rc" -eq 0 ] && first_rc=$1; return 0; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    all)
      for s in "${ALL_STEPS[@]}"; do
        step "$s"; rc=$?
        note "$rc"
        # nothing else can work without a successful install
        if [ "$s" = install ] && [ "$rc" -ne 0 ]; then finish "$rc"; fi
      done
      shift ;;
    sh)
      step sh "${2:-}"; note $?
      shift; [ "$#" -gt 0 ] && shift ;;
    *)
      step "$1"; note $?
      shift ;;
  esac
done
finish "$first_rc"
