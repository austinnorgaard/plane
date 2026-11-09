#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# service-paths.sh - the one place that maps repository paths to fork images
# (PLN-109). Used by .github/workflows/fork-images.yml (which images to build)
# and fork/deploy/update.sh (which commit last changed an image).
#
# Usage:
#   service-paths.sh pathspec <web|live|api>   print the git pathspecs, one per line
#   service-paths.sh classify                  read changed paths on stdin (one per
#                                              line), print the affected images in
#                                              the order web, live, api
#
# Mapping:
#   web   apps/web/**, packages/**, root package.json, pnpm-lock.yaml,
#         pnpm-workspace.yaml, turbo.json (apps/web/Dockerfile.web is under apps/web)
#   live  apps/live/**, packages/**, the same root files
#         (apps/live/Dockerfile.live is under apps/live)
#   api   apps/api/**, fork/docker/Dockerfile.fork-api
set -eu

ROOT_FILES=(package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json)

pathspec() {
  case "$1" in
    web) printf '%s\n' apps/web packages "${ROOT_FILES[@]}" ;;
    live) printf '%s\n' apps/live packages "${ROOT_FILES[@]}" ;;
    api) printf '%s\n' apps/api fork/docker/Dockerfile.fork-api ;;
    *) echo "service-paths.sh: unknown service '$1'" >&2; exit 2 ;;
  esac
}

# matches <svc> <path>: 0 when the path belongs to the image.
matches() {
  local p
  while IFS= read -r p; do
    case "$2" in
      "$p" | "$p"/*) return 0 ;;
    esac
  done < <(pathspec "$1")
  return 1
}

case "${1:-}" in
  pathspec)
    [ $# -eq 2 ] || { echo "usage: service-paths.sh pathspec <web|live|api>" >&2; exit 2; }
    pathspec "$2"
    ;;
  classify)
    hit_web=0 hit_live=0 hit_api=0
    while IFS= read -r f; do
      f="${f%$'\r'}"
      [ -n "$f" ] || continue
      if matches web "$f"; then hit_web=1; fi
      if matches live "$f"; then hit_live=1; fi
      if matches api "$f"; then hit_api=1; fi
    done
    if [ "$hit_web" = 1 ]; then echo web; fi
    if [ "$hit_live" = 1 ]; then echo live; fi
    if [ "$hit_api" = 1 ]; then echo api; fi
    ;;
  *)
    sed -n '4,19p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
