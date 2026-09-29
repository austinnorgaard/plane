#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# node-tests.sh - install and run Plane's node checks in node:22-alpine with the
# corepack-pinned pnpm (packageManager in package.json, 11.3.0 at v1.4.2).
#
# The source tree is bind-mounted at /work, so node_modules lives on the distro's
# ext4 disk. The named volume plane-pnpm-store is mounted at /pnpm and holds both
# the pnpm content store (/pnpm/store) and the corepack download cache
# (/pnpm/corepack), so re-runs need no network for pnpm itself.
#
# Usage (inside the WSL podman distro, as root):
#   node-tests.sh install              # pnpm install --frozen-lockfile
#   node-tests.sh build-libs           # build the workspace packages live and web depend on (@plane/editor, i18n, services, ...)
#   node-tests.sh live-test            # pnpm --filter live test          (vitest)
#   node-tests.sh live-types           # pnpm --filter live check:types   (tsc --noEmit)
#   node-tests.sh web-types            # pnpm --filter web check:types
#   node-tests.sh web-lint             # pnpm --filter web check:lint
#   node-tests.sh all                  # install, build-libs, then the four checks above
#   node-tests.sh sh 'any shell cmd'   # run an arbitrary command in the same container setup
#   PLANE_SRC=/root/plane-build/spike node-tests.sh all   # test a different tree
#
# From Windows:  wsl.exe -d <distro> -u root -- /root/plane-work/fork/test/node-tests.sh all
#
# Each step prints "NODETEST step=<name> rc=<code> wall_s=<n>". Logs go to OUT_DIR
# (default /root/plane-build/logs) as node-<step>.log. Exit code is the first
# non-zero step's code, but "all" always runs every step so the baseline is complete.
set -uo pipefail

SRC=${PLANE_SRC:-/root/plane-work}
OUT_DIR=${OUT_DIR:-/root/plane-build/logs}
IMAGE=${NODE_IMAGE:-docker.io/library/node:22-alpine}
VOLUME=plane-pnpm-store
NODE_HEAP_MB=${NODE_HEAP_MB:-4096}   # same cap the upstream CI uses for build/check:types
# NODE_CPUS caps the container (default 8 CPUs) so a run cannot starve other
# workloads that share the machine.

mkdir -p "$OUT_DIR"
[ -f "$SRC/package.json" ] || { echo "no package.json under PLANE_SRC=$SRC" >&2; exit 2; }
podman volume exists "$VOLUME" 2>/dev/null || podman volume create "$VOLUME" >/dev/null

# run_in_node NAME CMD  -> runs CMD (sh) in a fresh container, logs to node-NAME.log
run_in_node() {
  local name=$1 cmd=$2 start rc
  start=$(date +%s)
  podman run --rm --cpus="${NODE_CPUS:-8}" \
    -v "$SRC:/work" -v "$VOLUME:/pnpm" -w /work \
    -e CI=true -e COREPACK_HOME=/pnpm/corepack -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    -e pnpm_config_store_dir=/pnpm/store \
    -e TURBO_TELEMETRY_DISABLED=1 -e NEXT_TELEMETRY_DISABLED=1 \
    -e NODE_OPTIONS="--max-old-space-size=$NODE_HEAP_MB" \
    "$IMAGE" sh -c "apk add --no-cache libc6-compat >/dev/null 2>&1; corepack enable pnpm && $cmd" \
    2>&1 | tee "$OUT_DIR/node-$name.log"
  rc=${PIPESTATUS[0]}
  echo "NODETEST step=$name rc=$rc wall_s=$(( $(date +%s) - start ))"
  return "$rc"
}

step() {
  case "$1" in
    install)    run_in_node install    'pnpm --version && pnpm install --frozen-lockfile' ;;
    build-libs) run_in_node build-libs 'pnpm turbo run build --filter=live^... --filter=web^...' ;;
    live-test)  run_in_node live-test  'pnpm --filter live test' ;;
    live-types) run_in_node live-types 'pnpm --filter live check:types' ;;
    web-types)  run_in_node web-types  'pnpm --filter web check:types' ;;
    web-lint)   run_in_node web-lint   'pnpm --filter web check:lint' ;;
    sh)         run_in_node adhoc      "${2:?usage: node-tests.sh sh 'command'}" ;;
    *) echo "unknown step: $1" >&2; return 2 ;;
  esac
}

if [ "${1:-all}" = "all" ]; then
  first_rc=0
  for s in install build-libs live-test live-types web-types web-lint; do
    step "$s"; rc=$?
    [ "$first_rc" -eq 0 ] && first_rc=$rc
    # nothing else can work without a successful install
    if [ "$s" = install ] && [ "$rc" -ne 0 ]; then exit "$rc"; fi
  done
  exit "$first_rc"
else
  step "$@"
fi
