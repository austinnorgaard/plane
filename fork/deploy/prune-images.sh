#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# prune-images.sh - image retention for the fork images on the Plane container (PLN-64).
# Every update.sh deploy pulls new ghcr.io sha-* images; this removes the old ones.
#
# Runs on a workstation, like update.sh: ssh to the hypervisor, then `pct exec` into the
# Plane container. It only reads the FORK_* lines of plane.env and plane.env.update-prev,
# lists images and (with --apply) untags them. No registry login, no pull, no restart.
#
# Usage:
#   prune-images.sh [--apply] [--keep <n>]
#   prune-images.sh --print
#
#   (default)   dry run: connect, list every fork image with KEEP or REMOVE and the
#               reason, remove nothing.
#   --apply     remove the REMOVE images (docker image rm <repo>:<tag>, never --force).
#   --keep <n>  besides the current and the rollback tags, keep the <n> most recent other
#               fork tags of each image (default 1).
#   --print     print the remote command and exit, connecting nowhere.
#
# What is kept, per image (plane-fork-web, plane-fork-live, plane-fork-api):
#   - the current tag (FORK_<X>_TAG in plane.env);
#   - the update.sh rollback target (FORK_<X>_TAG in plane.env.update-prev);
#   - the <n> most recent other sha-* tags (by image creation time);
#   - any image a container uses (running or stopped).
# Only <FORK_REGISTRY>/plane-fork-{web,live,api}:sha-<hex> images are ever candidates:
# makeplane/* images, base images, the localhost/plane-fork-* images of the old live.N
# builds and untagged images are never touched. If plane.env has no valid current tag
# for an image, nothing of that image is removed.
#
# Required environment (as for update.sh):
#   PVE_HOST        ssh target of the hypervisor
#   PLANE_CTID      container id on the hypervisor (numeric)
#   PLANE_APP_DIR   absolute path of the plane-app directory in the container
#
# Exit status: 0 ok, 1 usage error, 2 a check failed (nothing removed), 3 a remote
# command failed or an image could not be removed (the others still are).
set -u

usage() {
  echo "usage: prune-images.sh [--apply] [--keep <n>] | --print" >&2
  exit 1
}
die() { echo "error: $*" >&2; exit 1; }

APPLY=0
PRINT=0
KEEP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --print) PRINT=1 ;;
    --keep) [ $# -ge 2 ] || usage; KEEP=$2; shift ;;
    --keep=*) KEEP=${1#--keep=} ;;
    -h|--help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage ;;
  esac
  shift
done
case "$KEEP" in ''|*[!0-9]*) die "--keep must be a number" ;; esac

: "${PVE_HOST:=}" "${PLANE_CTID:=}" "${PLANE_APP_DIR:=}"
{ [ -n "$PVE_HOST" ] && [ -n "$PLANE_CTID" ] && [ -n "$PLANE_APP_DIR" ]; } || die "set PVE_HOST, PLANE_CTID and PLANE_APP_DIR"
case "$PVE_HOST" in -*|*[!A-Za-z0-9._@:-]*) die "PVE_HOST has unexpected characters" ;; esac
case "$PLANE_CTID" in *[!0-9]*) die "PLANE_CTID must be numeric" ;; esac
case "$PLANE_APP_DIR" in /*) ;; *) die "PLANE_APP_DIR must be an absolute path" ;; esac
case "$PLANE_APP_DIR" in *[!A-Za-z0-9._/-]*) die "PLANE_APP_DIR has unexpected characters" ;; esac

# The remote script (POSIX sh, run inside the container).
read -r -d '' S_PRUNE <<'EOF'
cd "$APP_DIR" || { echo "STOP: cannot enter the app dir"; exit 2; }
[ -r plane.env ] || { echo "STOP: plane.env not readable"; exit 2; }
val() { # val <file> <key>: a FORK_* value, or empty when absent or odd
  [ -r "$1" ] || return 0
  v=$(sed -n "s/^$2=//p" "$1" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
  case "$v" in *[!A-Za-z0-9._/:-]*) ;; *) printf '%s' "$v" ;; esac
}
REG=$(val plane.env FORK_REGISTRY); REG=${REG:-ghcr.io/austinnorgaard}
PREV_REG=$(val plane.env.update-prev FORK_REGISTRY); PREV_REG=${PREV_REG:-$REG}
case "$REG" in *.*/*) ;; *) echo "STOP: FORK_REGISTRY '$REG' is not a registry/owner"; exit 2; esac
if [ -f plane.env.update-prev ]; then echo "rollback target: plane.env.update-prev"; else echo "rollback target: none (no plane.env.update-prev)"; fi
used=$(docker ps -a --format '{{.Image}}' </dev/null) || { echo "STOP: docker ps failed"; exit 3; }
used_ids=$(docker ps -aq </dev/null | xargs -r docker inspect -f '{{.Image}}') || { echo "STOP: docker inspect failed"; exit 3; }
W=$(mktemp -d) || { echo "STOP: mktemp failed"; exit 3; }
trap 'rm -rf "$W"' EXIT
for s in web live api; do
  case "$s" in web) key=FORK_WEB_TAG ;; live) key=FORK_LIVE_TAG ;; api) key=FORK_API_TAG ;; esac
  repo="$REG/plane-fork-$s"
  cur=$(val plane.env "$key")
  prev=""
  [ "$PREV_REG" = "$REG" ] && prev=$(val plane.env.update-prev "$key")
  echo "== $repo (current ${cur:-<none>}, rollback ${prev:-<none>})"
  list=$(docker image ls --format '{{.Tag}}' "$repo" </dev/null) || { echo "STOP: docker image ls failed"; exit 3; }
  rows=""
  for t in $list; do
    printf '%s' "$t" | grep -Eq '^sha-[0-9a-f]{7,40}$' || continue
    meta=$(docker image inspect -f '{{.Created}} {{.Id}} {{.Size}}' "$repo:$t" </dev/null) || continue
    rows="$rows$meta $t
"
  done
  if [ -z "$rows" ]; then echo "  no sha-* images"; continue; fi
  if ! printf '%s' "$cur" | grep -Eq '^sha-[0-9a-f]{7,40}$'; then
    echo "  SKIP: plane.env has no sha-* $key; nothing of this image is removed"
    continue
  fi
  extra=0
  # newest first; columns: created id size tag
  printf '%s' "$rows" | sort -r | while read -r created id size tag; do
    mb=$((size / 1000000))
    why=""
    if [ "$tag" = "$cur" ]; then why="current"
    elif [ -n "$prev" ] && [ "$tag" = "$prev" ]; then why="rollback target"
    elif printf '%s\n' "$used" | grep -qxF "$repo:$tag" || printf '%s\n' "$used_ids" | grep -qxF "$id"; then why="used by a container"
    elif [ "$extra" -lt "$KEEP" ]; then extra=$((extra + 1)); why="recent ($extra of $KEEP)"
    fi
    if [ -n "$why" ]; then
      echo "  KEEP   $tag  ${created%%.*}  ${mb} MB  ($why)"
    elif [ "$APPLY" = 1 ]; then
      if docker image rm "$repo:$tag" </dev/null >/dev/null 2>"$W/err"; then
        echo "  REMOVED $tag  ${created%%.*}  ${mb} MB"
      else
        echo "  FAILED $tag: $(tail -n 1 "$W/err")"
        : >"$W/failed"
      fi
    else
      echo "  REMOVE $tag  ${created%%.*}  ${mb} MB  (dry run)"
    fi
  done
done
rc=0
[ ! -f "$W/failed" ] || rc=3
if [ "$APPLY" = 1 ]; then echo "done; sizes are per image and shared layers are freed only once no tag uses them"; else echo "dry run: nothing removed (run with --apply to remove the REMOVE lines)"; fi
exit $rc
EOF

# sq <text>: POSIX single-quote text for the remote shell.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote="pct exec $PLANE_CTID -- env $(sq "APP_DIR=$PLANE_APP_DIR") $(sq "APPLY=$APPLY") $(sq "KEEP=$KEEP") sh -c $(sq "$S_PRUNE")"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

if [ "$PRINT" = 1 ]; then
  echo "+ ssh ${SSH_OPTS[*]} $PVE_HOST <remote command> </dev/null"
  echo "  remote command, sent as one argument:"
  printf '%s\n' "$remote" | sed 's/^/    /'
  exit 0
fi

if [ "$APPLY" = 1 ]; then echo "prune-images: removing old fork images (keep $KEEP extra per image)"; else echo "prune-images: dry run (keep $KEEP extra per image)"; fi
# shellcheck disable=SC2029  # expanding the command on the client side is intended
ssh "${SSH_OPTS[@]}" "$PVE_HOST" "$remote" </dev/null
rc=$?
case "$rc" in
  0) exit 0 ;;
  2) echo "RESULT: a check failed; nothing was removed" >&2; exit 2 ;;
  *) echo "RESULT: remote command failed (rc=$rc)" >&2; exit 3 ;;
esac
