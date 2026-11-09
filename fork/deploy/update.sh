#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# update.sh - the normal deploy (PLN-109): move the fork services to the CI-built
# images of one commit, restarting only the services whose image changes. No source
# build, no container (CT) restart, no other service touched.
#
# Runs on a workstation, like rollback.sh: ssh to the hypervisor, then `pct exec` into
# the Plane container. Nothing secret is printed or put in an argument list: plane.env
# is only read for the FORK_* and LISTEN_HTTP_PORT lines, and the compose `config`
# command is never used.
#
# Usage:
#   update.sh [--dry-run] [--notify] <sha> [--services web,live,api]
#   update.sh [--dry-run] [--notify] rollback
#   update.sh [--dry-run] status
#
#   <sha>       full 40-hex commit on origin/live-updates/v1.4.3.
#   --services  only these images (comma list of web, live, api). Default: every image
#               whose target tag differs from the one in plane.env and is newer. The
#               target of an image is sha-<sha> when CI built it for that commit (the
#               run's fork-images-manifest says which), otherwise sha-<the last commit
#               up to <sha> that changed its paths> (fork/build/service-paths.sh).
#               api covers api, worker and beat-worker (one image, FORK_API_TAG).
#   rollback    put back the tags recorded in plane.env.update-prev by the last update
#               or rollback (so a second rollback rolls forward again). Database
#               migrations are not reversed.
#   status      print the FORK_* lines, the recorded previous tags and the running images.
#   --dry-run   print every command that would run; connect nowhere, change nothing.
#   --notify    run UPDATE_PRE_CMD before the pull and UPDATE_POST_CMD after the health
#               checks (locally, with bash -c), for example to tell the Gavel team about
#               the hold window. Without --notify they are not run. They get UPDATE_MODE,
#               UPDATE_SHA, UPDATE_SERVICES and (post only) UPDATE_RESULT=ok|failed.
#
# Steps of an update:
#   1. preflight: the sha is on origin/live-updates/v1.4.3; the Fork images run for it
#      succeeded (gh); the images exist in GHCR (docker manifest inspect, inside the CT);
#      no rollback L1 file is active
#   2. record the current FORK_* values (plane.env.update-prev.<UTC time>, and
#      plane.env.update-prev.pending, which replaces plane.env.update-prev in step 5, so
#      an update that stops earlier keeps the old rollback target)
#   3. pull the changed images
#   4. if api changes: run the Django migrations with the NEW api image, before any
#      restart (skipped when `migrate --check` finds nothing to apply)
#   5. write the new tags into plane.env
#   6. up -d --no-deps --pull never <only the changed services>
#   7. bounded health poll: web /, live /live/health (5 min each), api /api/instances/
#      (15 min, the boot is slow under disk load)
#   8. result with timings. A failed health check prints how to roll back; nothing is
#      rolled back automatically.
#
# Registry login (the images are PRIVATE): nothing is stored on the CT. Each step that
# talks to ghcr.io logs in for that step only: the workstation token from
# `gh auth token` (needs the read:packages scope; prereq once:
# `gh auth refresh -h github.com -s read:packages`) is piped over ssh into the
# `pct exec` stdin and read by `docker login --password-stdin`, with DOCKER_CONFIG set
# to a fresh 0700 directory /run/plane-update.<id> in the CT. A trap removes that
# directory on every exit of the remote step, and this script removes it again on its
# own exit (also Ctrl-C).
#
# Required environment (operator supplied, no defaults):
#   PVE_HOST        ssh target of the hypervisor
#   PLANE_CTID      container id on the hypervisor (numeric)
#   PLANE_APP_DIR   absolute path of the plane-app directory in the container
# Optional:
#   UPDATE_PRE_CMD, UPDATE_POST_CMD   hooks for --notify (default: none)
#   UPDATE_HEALTH_BASE  base URL of the health checks inside the CT
#                       (default http://127.0.0.1:<LISTEN_HTTP_PORT from plane.env, or 80>)
#   UPDATE_HEALTH_HOST  Host header for the health checks (default: none)
#
# Exit status: 0 ok, 1 usage or prerequisite error, 2 a check failed (nothing changed
# when it happens before step 5), 3 a remote command failed, 4 the registry refused the
# login or an image (token or scope), 5 health check failed (see the rollback hint).
set -u

BRANCH=live-updates/v1.4.3
GH_REPO=austinnorgaard/plane
WORKFLOW=fork-images.yml
REGISTRY=ghcr.io/austinnorgaard
REG_HOST=ghcr.io
SERVICES_ALL="web live api"
C='docker compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$here/../.."
paths_sh="$here/../build/service-paths.sh"

usage() {
  echo "usage: update.sh [--dry-run] [--notify] <sha> [--services web,live,api]" >&2
  echo "       update.sh [--dry-run] [--notify] rollback | status" >&2
  exit 1
}
die() { echo "error: $*" >&2; exit 1; }

DRY=0
NOTIFY=0
MODE=
SHA=
SVC_ARG=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --notify) NOTIFY=1 ;;
    --services) [ $# -ge 2 ] || usage; SVC_ARG=$2; shift ;;
    --services=*) SVC_ARG=${1#--services=} ;;
    -h|--help) sed -n '2,73p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    rollback|status) [ -z "$MODE" ] || usage; MODE=$1 ;;
    -*) usage ;;
    *) [ -z "$MODE" ] || usage; MODE=update; SHA=$(printf '%s' "$1" | tr 'A-F' 'a-f') ;;
  esac
  shift
done
[ -n "$MODE" ] || usage
if [ "$MODE" = update ]; then
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "the sha must be 40 hex digits"
elif [ -n "$SVC_ARG" ]; then
  die "--services only applies to an update"
fi

: "${PVE_HOST:=}" "${PLANE_CTID:=}" "${PLANE_APP_DIR:=}"
{ [ -n "$PVE_HOST" ] && [ -n "$PLANE_CTID" ] && [ -n "$PLANE_APP_DIR" ]; } || die "set PVE_HOST, PLANE_CTID and PLANE_APP_DIR"
case "$PVE_HOST" in -*|*[!A-Za-z0-9._@:-]*) die "PVE_HOST has unexpected characters" ;; esac
case "$PLANE_CTID" in *[!0-9]*) die "PLANE_CTID must be numeric" ;; esac
case "$PLANE_APP_DIR" in /*) ;; *) die "PLANE_APP_DIR must be an absolute path" ;; esac
case "$PLANE_APP_DIR" in *[!A-Za-z0-9._/-]*) die "PLANE_APP_DIR has unexpected characters" ;; esac
HEALTH_BASE=${UPDATE_HEALTH_BASE:-}
HEALTH_HOST=${UPDATE_HEALTH_HOST:-}
case "$HEALTH_BASE" in ''|http://*|https://*) ;; *) die "UPDATE_HEALTH_BASE must start with http:// or https://" ;; esac
case "$HEALTH_BASE$HEALTH_HOST" in *[!A-Za-z0-9._:/\[\]-]*) die "UPDATE_HEALTH_BASE/UPDATE_HEALTH_HOST have unexpected characters" ;; esac

# Selected services, validated, in the order web live api.
SELECT_ARG=
if [ -n "$SVC_ARG" ]; then
  for s in $(printf '%s' "$SVC_ARG" | tr ',' ' '); do
    case "$s" in web|live|api) ;; *) die "unknown service '$s' in --services (use web, live, api)" ;; esac
  done
  for s in $SERVICES_ALL; do
    case ",$SVC_ARG," in *",$s,"*) SELECT_ARG="$SELECT_ARG $s" ;; esac
  done
  SELECT_ARG=${SELECT_ARG# }
fi

# compose services of an image
compose_services() { # compose_services "<images, space separated>"
  local out='' s
  for s in $1; do
    case "$s" in
      web) out="$out web" ;;
      live) out="$out live" ;;
      api) out="$out api worker beat-worker" ;;
    esac
  done
  echo "${out# }"
}
key_of() { case "$1" in web) echo FORK_WEB_TAG ;; live) echo FORK_LIVE_TAG ;; api) echo FORK_API_TAG ;; esac; }

RUN_ID="$$-$(date +%s)"
RUN_DIR="/run/plane-update.$RUN_ID"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

# sq <text>: POSIX single-quote text for the remote shell.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
now() { if [ -n "${EPOCHREALTIME:-}" ]; then echo "${EPOCHREALTIME/[.,]/}" | cut -c1-16; else echo "$(date +%s)000000"; fi; }
secs() { echo $(( ($(now) - $1) / 1000000 )); }

TMP=$(mktemp)
TMPD=$(mktemp -d)
LOGIN_USED=0
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup_local() {
  rm -f "$TMP"
  rm -rf "$TMPD"
  if [ "$DRY" = 0 ] && [ "$LOGIN_USED" = 1 ]; then
    # Second line of defence: the remote trap already removed it unless ssh was cut.
    timeout 30 ssh "${SSH_OPTS[@]}" "$PVE_HOST" "pct exec $PLANE_CTID -- rm -rf $RUN_DIR" </dev/null >/dev/null 2>&1 || true
  fi
}
trap cleanup_local EXIT
trap 'echo; echo "interrupted" >&2; exit 130' INT TERM HUP

# Shell preamble of every remote step that talks to the registry. The token is the
# only thing on stdin; every later command reads /dev/null.
read -r -d '' S_LOGIN <<'EOF'
umask 077
D=$RUN_DIR
[ -d /run ] || { echo "STOP: /run does not exist in the container"; exit 2; }
mkdir -m 700 "$D" || { echo "STOP: cannot create $D"; exit 2; }
cleanup() { rm -rf "$D"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
export DOCKER_CONFIG="$D"
if ! docker login "$REG_HOST" -u "$GH_USER" --password-stdin >"$D/login.out" 2>&1; then
  tail -n 2 "$D/login.out" | sed 's/^/  docker: /'
  echo "AUTH: docker login to $REG_HOST was refused. The workstation token (gh auth token) is missing, expired or lacks read:packages, or $GH_USER cannot read the private packages. Run: gh auth refresh -h github.com -s read:packages"
  exit 4
fi
denied() { grep -qiE 'unauthorized|denied|authentication required|403 forbidden' "$1"; }
EOF

# Reads the FORK_* lines of plane.env (values only for these keys, never other lines).
read -r -d '' S_ENVREAD <<'EOF'
cd "$APP_DIR" || { echo "STOP: cannot enter the app dir"; exit 2; }
[ -r plane.env ] || { echo "STOP: plane.env not readable"; exit 2; }
val() {
  v=$(sed -n "s/^$1=//p" plane.env | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
  case "$v" in *[!A-Za-z0-9._/:-]*) echo "<invalid>" ;; *) echo "$v" ;; esac
}
EOF

read -r -d '' S_PROBE <<'EOF'
echo "cur.registry=$(r=$(val FORK_REGISTRY); echo "${r:-ghcr.io/austinnorgaard}")"
echo "cur.web=$(val FORK_WEB_TAG)"
echo "cur.live=$(val FORK_LIVE_TAG)"
echo "cur.api=$(val FORK_API_TAG)"
if [ -f docker-compose.override.l1.yaml ]; then echo "l1=present"; else echo "l1=absent"; fi
[ -f docker-compose.override.yaml ] || { echo "STOP: docker-compose.override.yaml not found"; exit 2; }
if grep -q 'FORK_WEB_TAG' docker-compose.override.yaml; then echo "override=tags"; else echo "override=old"; fi
bad=0
for ref in $PROBE; do
  if docker manifest inspect "$REGISTRY/$ref" >/dev/null 2>"$D/inspect.err" </dev/null; then
    echo "img.$ref=present"
  elif denied "$D/inspect.err"; then
    echo "img.$ref=denied"; bad=1
  else
    echo "img.$ref=missing"
  fi
done
if [ "$bad" = 1 ]; then
  echo "AUTH: ghcr.io refused 'docker manifest inspect' for a private image although the login worked: the token lacks read:packages or $GH_USER has no access to the package."
  exit 4
fi
EOF

read -r -d '' S_RECORD <<'EOF'
ts=$(date -u +%Y%m%dT%H%M%SZ)
{
  echo "# fork/deploy/update.sh: FORK_* values before the $UPD_MODE at $ts UTC"
  echo "FORK_REGISTRY=$CUR_REGISTRY"
  echo "FORK_WEB_TAG=$CUR_WEB"
  echo "FORK_LIVE_TAG=$CUR_LIVE"
  echo "FORK_API_TAG=$CUR_API"
} > plane.env.update-prev.pending || { echo "STOP: cannot write plane.env.update-prev.pending"; exit 2; }
cp plane.env.update-prev.pending "plane.env.update-prev.$ts" || { echo "STOP: cannot write the timestamped copy"; exit 2; }
echo "recorded the current tags in plane.env.update-prev.$ts (they become plane.env.update-prev when the new tags are written)"
EOF

read -r -d '' S_PULL <<'EOF'
cd "$APP_DIR" || exit 2
env $TAGS $C pull $PULL_SVCS </dev/null >"$D/pull.out" 2>&1
rc=$?
tail -n 20 "$D/pull.out"
if [ "$rc" != 0 ]; then
  if denied "$D/pull.out"; then
    echo "AUTH: ghcr.io refused the pull: the token lacks read:packages or $GH_USER has no access to the package."
    exit 4
  fi
  echo "STOP: pull failed (rc=$rc); nothing was restarted and plane.env is unchanged"
  exit 2
fi
EOF

read -r -d '' S_MIGRATE <<'EOF'
cd "$APP_DIR" || exit 2
if env $TAGS $C run --rm --no-deps -T --entrypoint python api manage.py migrate --check </dev/null; then
  echo "migrations: nothing to apply"
  exit 0
fi
echo "migrations: applying with the new api image"
env $TAGS $C run --rm --no-deps -T --entrypoint python api manage.py migrate --noinput </dev/null ||
  { echo "STOP: migrate failed; nothing was restarted and plane.env is unchanged"; exit 2; }
EOF

read -r -d '' S_WRITE <<'EOF'
cd "$APP_DIR" || exit 2
# the tags recorded in step 2 become the rollback target only now that they are replaced
mv plane.env.update-prev.pending plane.env.update-prev || { echo "STOP: plane.env.update-prev.pending is missing; nothing was written"; exit 2; }
[ -z "$(tail -c 1 plane.env)" ] || printf '\n' >> plane.env
for kv in $TAGS; do
  k=${kv%%=*}
  if grep -q "^$k=" plane.env; then
    sed -i "s|^$k=.*|$kv|" plane.env || { echo "STOP: cannot edit plane.env"; exit 2; }
  else
    printf '%s\n' "$kv" >> plane.env || { echo "STOP: cannot edit plane.env"; exit 2; }
  fi
  [ "$(grep -c "^$k=" plane.env)" = 1 ] && grep -qx "$kv" plane.env || { echo "STOP: $k is not set as expected in plane.env"; exit 2; }
  echo "plane.env: $kv"
done
EOF

read -r -d '' S_UP <<'EOF'
cd "$APP_DIR" || exit 2
$C up -d --no-deps --pull never $UP_SVCS </dev/null
EOF

read -r -d '' S_HEALTH <<'EOF'
cd "$APP_DIR" || exit 2
base=$HEALTH_BASE
if [ -z "$base" ]; then
  p=$(sed -n 's/^LISTEN_HTTP_PORT=//p' plane.env | tail -n 1 | tr -d '"'"'"' ')
  case "$p" in ''|*[!0-9]*) p=80 ;; esac
  base="http://127.0.0.1:$p"
fi
code() {
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$HEALTH_HOST" ]; then curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $HEALTH_HOST" "$1"
    else curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1"; fi
  else
    if [ -n "$HEALTH_HOST" ]; then wget -q -S -O /dev/null -T 10 --header "Host: $HEALTH_HOST" "$1" 2>&1
    else wget -q -S -O /dev/null -T 10 "$1" 2>&1; fi | awk '/HTTP\//{c=$2} END{print c+0}'
  fi
}
fail=0
for check in $CHECKS; do
  name=${check%%:*}; rest=${check#*:}; limit=${rest%%:*}; path=${rest#*:}
  start=$(date +%s); last=-; next=30
  while :; do
    c=$(code "$base$path" </dev/null); last=${c:-000}
    t=$(( $(date +%s) - start ))
    if [ "$last" = 200 ]; then echo "HEALTH $name $path: 200 after ${t}s"; break; fi
    if [ "$t" -ge "$limit" ]; then echo "HEALTH $name $path: FAILED, last status $last after ${t}s"; fail=1; break; fi
    if [ "$t" -ge "$next" ]; then echo "  ... $name $path: status $last after ${t}s (limit ${limit}s)"; next=$((next + 30)); fi
    sleep 5
  done
done
[ "$fail" = 0 ] || exit 5
EOF

read -r -d '' S_STATUS <<'EOF'
for k in FORK_REGISTRY FORK_WEB_TAG FORK_LIVE_TAG FORK_API_TAG FORK_N; do echo "plane.env $k=$(val $k)"; done
if [ -f plane.env.update-prev ]; then
  grep -E '^FORK_(REGISTRY|WEB_TAG|LIVE_TAG|API_TAG)=' plane.env.update-prev | sed 's/^/update-prev /'
else
  echo "update-prev: none"
fi
echo "timestamped copies: $(ls plane.env.update-prev.* 2>/dev/null | wc -l | tr -d ' ')"
if [ -f docker-compose.override.l1.yaml ]; then echo "rollback L1 file: present"; else echo "rollback L1 file: absent"; fi
$C ps --format '{{.Service}} {{.Image}} {{.Status}}' </dev/null | grep -E '^(web|live|api|worker|beat-worker) '
EOF

read -r -d '' S_PREVREAD <<'EOF'
[ -f plane.env.update-prev ] || { echo "STOP: no plane.env.update-prev; nothing to roll back to"; exit 2; }
pv() {
  v=$(sed -n "s/^$1=//p" plane.env.update-prev | tail -n 1)
  case "$v" in *[!A-Za-z0-9._/:-]*) echo "<invalid>" ;; *) echo "$v" ;; esac
}
echo "prev.registry=$(pv FORK_REGISTRY)"
echo "prev.web=$(pv FORK_WEB_TAG)"
echo "prev.live=$(pv FORK_LIVE_TAG)"
echo "prev.api=$(pv FORK_API_TAG)"
echo "cur.registry=$(r=$(val FORK_REGISTRY); echo "${r:-ghcr.io/austinnorgaard}")"
echo "cur.web=$(val FORK_WEB_TAG)"
echo "cur.live=$(val FORK_LIVE_TAG)"
echo "cur.api=$(val FORK_API_TAG)"
if [ -f docker-compose.override.l1.yaml ]; then echo "l1=present"; else echo "l1=absent"; fi
EOF

read -r -d '' S_LOCALIMG <<'EOF'
missing=
for ref in $REFS; do
  docker image inspect "$ref" >/dev/null 2>&1 </dev/null || missing="$missing $ref"
done
[ -z "$missing" ] || { echo "STOP: not in the local image store:$missing"; exit 2; }
echo "local images present: $REFS"
EOF

OUT=
LAST_SECS=0
TOTAL_START=$(now)
declare -A TIMES=()
STEP_ORDER=()

# step <label> <token:0|1> <script> [VAR=value...]: run one remote script, time it.
# Returns the remote rc in STEP_RC (0, 2, 3, 4, 5); exits on 2/3/4 unless STEP_SOFT=1.
STEP_RC=0
step() {
  local label=$1 token=$2 script=$3 rc t0 assigns="" kv
  shift 3
  for kv in APP_DIR="$PLANE_APP_DIR" "$@"; do assigns="$assigns $(sq "$kv")"; done
  local remote
  remote="pct exec $PLANE_CTID -- env$assigns sh -c $(sq "$script")"
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] $label"
    if [ "$token" = 1 ]; then
      echo "+ <token from gh auth token> | ssh ${SSH_OPTS[*]} $PVE_HOST <remote command>"
    else
      echo "+ ssh ${SSH_OPTS[*]} $PVE_HOST <remote command> </dev/null"
    fi
    echo "  remote command, sent as one argument:"
    printf '%s\n' "$remote" | sed 's/^/    /'
    OUT=
    STEP_RC=0
    return 0
  fi
  echo "== $label"
  t0=$(now)
  if [ "$token" = 1 ]; then
    LOGIN_USED=1
    # shellcheck disable=SC2029  # expanding the command on the client side is intended
    gh auth token -h github.com 2>/dev/null | ssh "${SSH_OPTS[@]}" "$PVE_HOST" "$remote" 2>&1 | tee "$TMP"
    rc=${PIPESTATUS[1]}
  else
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$PVE_HOST" "$remote" </dev/null 2>&1 | tee "$TMP"
    rc=${PIPESTATUS[0]}
  fi
  OUT=$(<"$TMP")
  LAST_SECS=$(secs "$t0")
  TIMES[$label]=$LAST_SECS
  STEP_ORDER+=("$label")
  echo "TIME $label: ${LAST_SECS} s"
  STEP_RC=$rc
  case "$rc" in
    0) return 0 ;;
    5) return 0 ;;
    2) echo "RESULT: $MODE stopped in '$label', a check failed; no further steps were run" >&2; exit 2 ;;
    4) echo "RESULT: $MODE stopped in '$label': registry access refused (see the AUTH line); no further steps were run" >&2; exit 4 ;;
    *) echo "RESULT: $MODE failed in step '$label' (rc=$rc); no further steps were run" >&2; exit 3 ;;
  esac
}

kv() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | tail -n 1; }

hook() { # hook pre|post
  local which=$1 cmd
  if [ "$which" = pre ]; then cmd=${UPDATE_PRE_CMD:-}; else cmd=${UPDATE_POST_CMD:-}; fi
  local var
  var="UPDATE_$(printf '%s' "$which" | tr '[:lower:]' '[:upper:]')_CMD"
  [ "$NOTIFY" = 1 ] || return 0
  if [ -z "$cmd" ]; then echo "notify: $var is not set, nothing to run"; return 0; fi
  if [ "$DRY" = 1 ]; then echo "[dry-run] notify $which: + bash -c <\$$var>"; return 0; fi
  echo "== notify $which ($var)"
  bash -c "$cmd" || echo "WARN: $var exited non-zero; continuing" >&2
}

gh_preflight() {
  if [ "$DRY" = 1 ]; then
    echo "+ gh auth status -h github.com   (must list read:packages or write:packages)"
    echo "+ gh api user --jq .login"
    GH_USER='<gh user>'
    return 0
  fi
  command -v gh >/dev/null 2>&1 || die "gh is required: the registry token comes from 'gh auth token'"
  local st
  st=$(gh auth status -h github.com 2>&1) || die "gh is not logged in to github.com (gh auth login, then gh auth refresh -h github.com -s read:packages)"
  if printf '%s\n' "$st" | grep -qi 'token scopes'; then
    printf '%s\n' "$st" | grep -i 'token scopes' | grep -qE "'(read|write):packages'" ||
      die "the gh token lacks the read:packages scope; run: gh auth refresh -h github.com -s read:packages"
  else
    echo "WARN: gh auth status shows no token scopes; cannot confirm read:packages (the registry will tell)" >&2
  fi
  GH_USER=$(gh api user --jq .login 2>/dev/null) || die "cannot read the gh user (gh api user)"
  case "$GH_USER" in ''|*[!A-Za-z0-9-]*) die "unexpected gh user name" ;; esac
}

print_times() {
  local l
  for l in "${STEP_ORDER[@]}"; do printf '  %-48s %6s s\n' "$l" "${TIMES[$l]}"; done
  echo "  total: $(secs "$TOTAL_START") s"
}

# ---------------------------------------------------------------- status
if [ "$MODE" = status ]; then
  step "status" 0 "$S_ENVREAD
$S_STATUS" "C=$C"
  exit 0
fi

gh_preflight

# ---------------------------------------------------------------- rollback
if [ "$MODE" = rollback ]; then
  step "read previous and current tags" 0 "$S_ENVREAD
$S_PREVREAD"
  declare -A PREV=() CURR=()
  if [ "$DRY" = 1 ]; then
    P_REG="$REGISTRY"; CUR_REG='<current registry>' # assumed; the real run reads it from plane.env.update-prev
    CHANGE="$SERVICES_ALL"
    for s in $SERVICES_ALL; do PREV[$s]="<prev $s tag>"; CURR[$s]="<current $s tag>"; done
  else
    [ "$(kv l1)" = absent ] || die "the rollback L1 file is active; run 'rollback.sh forward' first"
    P_REG=$(kv prev.registry); CUR_REG=$(kv cur.registry)
    for s in $SERVICES_ALL; do PREV[$s]=$(kv "prev.$s"); CURR[$s]=$(kv "cur.$s"); done
    for v in "$P_REG" "${PREV[web]}" "${PREV[live]}" "${PREV[api]}"; do
      case "$v" in ''|'<invalid>') die "plane.env.update-prev is incomplete or has unexpected characters; fix it by hand" ;; esac
    done
    CHANGE=
    for s in $SERVICES_ALL; do
      if [ "$P_REG" != "$CUR_REG" ] || [ "${PREV[$s]}" != "${CURR[$s]}" ]; then CHANGE="$CHANGE $s"; fi
    done
    CHANGE=${CHANGE# }
    [ -n "$CHANGE" ] || { echo "RESULT: the previous tags equal the current ones; nothing to do"; exit 0; }
  fi
  echo "PLAN rollback (registry ${CUR_REG} -> ${P_REG}):"
  for s in $CHANGE; do echo "  $s: ${CURR[$s]} -> ${PREV[$s]}"; done
  echo "  database migrations are NOT reversed"
  TAGS="FORK_REGISTRY=$P_REG"
  REFS=
  for s in $CHANGE; do TAGS="$TAGS $(key_of "$s")=${PREV[$s]}"; REFS="$REFS $P_REG/plane-fork-$s:${PREV[$s]}"; done
  REFS=${REFS# }
  export UPDATE_MODE=rollback UPDATE_SHA='' UPDATE_SERVICES="$CHANGE"
  hook pre
  case "$P_REG" in
    "$REG_HOST"/*)
      step "pull the previous images" 1 "$S_LOGIN
$S_PULL" "RUN_DIR=$RUN_DIR" "REG_HOST=$REG_HOST" "GH_USER=$GH_USER" "C=$C" "TAGS=$TAGS" "PULL_SVCS=$CHANGE" ;;
    *)
      step "check the previous images are local" 0 "$S_LOCALIMG" "REFS=$REFS" ;;
  esac
  step "record the current tags" 0 "cd \"\$APP_DIR\" || exit 2
$S_RECORD" "UPD_MODE=rollback" "CUR_REGISTRY=$CUR_REG" "CUR_WEB=${CURR[web]}" "CUR_LIVE=${CURR[live]}" "CUR_API=${CURR[api]}"
  step "write the previous tags into plane.env" 0 "$S_WRITE" "TAGS=$TAGS"
  step "up -d --no-deps $(compose_services "$CHANGE")" 0 "$S_UP" "C=$C" "UP_SVCS=$(compose_services "$CHANGE")"
  CHECKS=
  for s in $CHANGE; do
    case "$s" in web) CHECKS="$CHECKS web:300:/" ;; live) CHECKS="$CHECKS live:300:/live/health" ;; api) CHECKS="$CHECKS api:900:/api/instances/" ;; esac
  done
  step "health checks" 0 "$S_HEALTH" "CHECKS=${CHECKS# }" "HEALTH_BASE=$HEALTH_BASE" "HEALTH_HOST=$HEALTH_HOST"
  HRC=$STEP_RC
  if [ "$HRC" = 0 ]; then UPDATE_RESULT=ok; else UPDATE_RESULT=failed; fi
  export UPDATE_RESULT
  hook post
  if [ "$DRY" = 1 ]; then echo "RESULT: dry-run only, nothing was run"; exit 0; fi
  print_times
  if [ "$HRC" != 0 ]; then
    echo "RESULT: rollback applied but a health check FAILED. Look at: $C logs --tail 100 $(compose_services "$CHANGE")" >&2
    exit 5
  fi
  echo "RESULT: rollback done ($CHANGE). 'update.sh rollback' again returns to the tags before it."
  exit 0
fi

# ---------------------------------------------------------------- update
# 1. preflight: sha on the branch (local git; the fetch reads origin only)
if [ "$DRY" = 1 ]; then
  echo "+ git -C <repo> fetch origin $BRANCH --quiet"
  echo "+ git -C <repo> merge-base --is-ancestor $SHA origin/$BRANCH"
else
  git -C "$repo" fetch origin "$BRANCH" --quiet || die "git fetch origin $BRANCH failed"
  git -C "$repo" merge-base --is-ancestor "$SHA" "origin/$BRANCH" ||
    { echo "STOP: $SHA is not on origin/$BRANCH" >&2; exit 2; }
  echo "sha ok: $SHA is on origin/$BRANCH"
fi

# 1b. the CI run for the sha, and its manifest
MANIFEST_BUILT=
if [ "$DRY" = 1 ]; then
  echo "+ gh run list -R $GH_REPO -w $WORKFLOW -c $SHA -L 20 --json databaseId,status,conclusion"
  echo "+ gh run download <run id> -R $GH_REPO -n fork-images-manifest -D <tmp>"
else
  runs=$(gh run list -R "$GH_REPO" -w "$WORKFLOW" -c "$SHA" -L 20 --json databaseId,status,conclusion \
    --jq '.[] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null) || runs=__error__
  if [ "$runs" = __error__ ]; then
    echo "WARN: gh run list failed; the CI result for $SHA is not checked" >&2
  elif [ -z "$runs" ]; then
    echo "WARN: no '$WORKFLOW' run for $SHA (fine if the images come from an earlier commit or a manual run); relying on the image check" >&2
  else
    ok_run=$(printf '%s\n' "$runs" | awk '$2 == "completed" && $3 == "success" {print $1; exit}')
    if [ -z "$ok_run" ]; then
      printf '%s\n' "$runs" | sed 's/^/  run /' >&2
      echo "STOP: no successful '$WORKFLOW' run for $SHA (failed or still running)" >&2
      exit 2
    fi
    echo "CI ok: run $ok_run succeeded for $SHA"
    if gh run download "$ok_run" -R "$GH_REPO" -n fork-images-manifest -D "$TMPD" >/dev/null 2>&1 && [ -f "$TMPD/fork-images-manifest.json" ]; then
      flat=$(tr -d ' \n\r\t' < "$TMPD/fork-images-manifest.json")
      msha=$(printf '%s' "$flat" | sed -n 's/.*"sha":"\([0-9a-f]\{40\}\)".*/\1/p')
      [ "$msha" = "$SHA" ] || { echo "STOP: the run's manifest names another sha ($msha)" >&2; exit 2; }
      MANIFEST_BUILT=$(printf '%s' "$flat" | sed -n 's/.*"built":\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ')
      echo "manifest: built for $SHA: ${MANIFEST_BUILT:-none}"
      printf '%s' "$flat" | grep -oE '"(web|live|api)":\{[^}]*\}' | sed -n 's/^"\([a-z]*\)".*"digest":"\([^"]*\)".*/  \1 digest \2/p'
    else
      echo "WARN: could not download the manifest of run $ok_run; relying on the image check" >&2
    fi
  fi
fi

# 1c. candidate tags per image: sha-<SHA>, and sha-<last commit up to SHA that changed it>
declare -A LASTC=()
PROBE=
for s in $SERVICES_ALL; do
  last=
  if git -C "$repo" cat-file -e "$SHA^{commit}" 2>/dev/null; then
    mapfile -t specs < <(bash "$paths_sh" pathspec "$s")
    last=$(git -C "$repo" log -1 --format=%H "$SHA" -- "${specs[@]}" 2>/dev/null)
  fi
  LASTC[$s]=$last
  PROBE="$PROBE plane-fork-$s:sha-$SHA"
  [ -z "$last" ] || [ "$last" = "$SHA" ] || PROBE="$PROBE plane-fork-$s:sha-$last"
done
PROBE=${PROBE# }

step "preflight in the CT: current tags and image check in $REGISTRY" 1 "$S_ENVREAD
$S_LOGIN
$S_PROBE" "RUN_DIR=$RUN_DIR" "REG_HOST=$REG_HOST" "GH_USER=$GH_USER" "REGISTRY=$REGISTRY" "PROBE=$PROBE"

declare -A CUR=() TARGET=() WHY=()
if [ "$DRY" = 1 ]; then
  CUR_REG='<current registry>'
  for s in $SERVICES_ALL; do CUR[$s]="<current $s tag>"; done
else
  [ "$(kv l1)" = absent ] || { echo "STOP: the rollback L1 file is active; run 'rollback.sh forward' first" >&2; exit 2; }
  [ "$(kv override)" = tags ] || { echo "STOP: the installed docker-compose.override.yaml has no FORK_*_TAG lines; do the one-time switch first (RUNBOOK 'Updates')" >&2; exit 2; }
  CUR_REG=$(kv cur.registry)
  for s in $SERVICES_ALL; do CUR[$s]=$(kv "cur.$s"); done
fi

for s in $SERVICES_ALL; do
  last=${LASTC[$s]}
  if [ "$DRY" = 1 ]; then
    if [ "$last" = "$SHA" ] || [ -z "$last" ]; then TARGET[$s]="sha-$SHA"; else TARGET[$s]="sha-$last (or sha-$SHA if CI built it)"; fi
    continue
  fi
  if [ "$(kv "img.plane-fork-$s:sha-$SHA")" = present ]; then
    TARGET[$s]="sha-$SHA"
  elif [ -n "$last" ] && [ "$(kv "img.plane-fork-$s:sha-$last")" = present ]; then
    TARGET[$s]="sha-$last"
  else
    TARGET[$s]=
  fi
  case " $MANIFEST_BUILT " in
    *" $s "*) [ "${TARGET[$s]}" = "sha-$SHA" ] || { echo "STOP: the manifest says $s was built for $SHA, but $REGISTRY/plane-fork-$s:sha-$SHA is missing" >&2; exit 2; } ;;
  esac
done

# Selection.
REG_SWITCH=0
[ "$DRY" = 1 ] || [ "$CUR_REG" = "$REGISTRY" ] || REG_SWITCH=1
CHANGE=
for s in $SERVICES_ALL; do
  t=${TARGET[$s]} c=${CUR[$s]}
  explicit=0
  case " $SELECT_ARG " in *" $s "*) explicit=1 ;; esac
  if [ -n "$SELECT_ARG" ] && [ "$explicit" = 0 ] && [ "$REG_SWITCH" = 0 ]; then WHY[$s]="not selected"; continue; fi
  if [ "$DRY" = 1 ]; then CHANGE="$CHANGE $s"; WHY[$s]="dry-run: current tag and image not checked"; continue; fi
  if [ -z "$t" ]; then
    if [ "$explicit" = 1 ] || [ "$REG_SWITCH" = 1 ]; then
      echo "STOP: no image for $s: neither sha-$SHA nor sha-${LASTC[$s]:-?} exists in $REGISTRY. Run the '$WORKFLOW' workflow by hand with services=$s and sha=$SHA, then retry." >&2
      exit 2
    fi
    WHY[$s]="no CI image found (sha-${LASTC[$s]:0:12}...); kept"
    continue
  fi
  if [ "$REG_SWITCH" = 1 ]; then CHANGE="$CHANGE $s"; WHY[$s]="registry switch $CUR_REG -> $REGISTRY"; continue; fi
  if [ "$t" = "$c" ]; then WHY[$s]="already on $t"; continue; fi
  if [ "$explicit" = 1 ]; then CHANGE="$CHANGE $s"; WHY[$s]="requested"; continue; fi
  if [[ "$c" =~ ^sha-[0-9a-f]{40}$ ]]; then
    cc=${c#sha-}
    if git -C "$repo" merge-base --is-ancestor "$cc" "${t#sha-}" 2>/dev/null; then
      CHANGE="$CHANGE $s"; WHY[$s]="newer than the current tag"
    else
      WHY[$s]="current tag is not older than $t; kept (use --services $s to force)"
    fi
  else
    CHANGE="$CHANGE $s"; WHY[$s]="current tag '$c' is not a CI tag"
  fi
done
CHANGE=${CHANGE# }

echo "PLAN for $SHA (registry $REGISTRY):"
for s in $SERVICES_ALL; do
  printf '  %-5s %s -> %s  (%s)\n' "$s" "${CUR[$s]:-<unset>}" "${TARGET[$s]:-<none>}" "${WHY[$s]}"
done
if [ -z "$CHANGE" ]; then echo "RESULT: nothing to change"; exit 0; fi
echo "  restart: $(compose_services "$CHANGE"); every other service is left alone"

TAGS="FORK_REGISTRY=$REGISTRY"
for s in $CHANGE; do
  if [ "$DRY" = 1 ]; then tag="<target $s tag>"; else tag=${TARGET[$s]}; fi
  TAGS="$TAGS $(key_of "$s")=$tag"
done
TAGS=${TAGS# }
export UPDATE_MODE=update UPDATE_SHA="$SHA" UPDATE_SERVICES="$CHANGE"

# 2. record
if [ "$DRY" = 1 ]; then CW='<current web tag>' CL='<current live tag>' CA='<current api tag>'; else CW=${CUR[web]} CL=${CUR[live]} CA=${CUR[api]}; fi
step "record the current tags" 0 "cd \"\$APP_DIR\" || exit 2
$S_RECORD" "UPD_MODE=update to $SHA" "CUR_REGISTRY=$CUR_REG" "CUR_WEB=$CW" "CUR_LIVE=$CL" "CUR_API=$CA"

hook pre

# 3. pull
step "pull $CHANGE" 1 "$S_LOGIN
$S_PULL" "RUN_DIR=$RUN_DIR" "REG_HOST=$REG_HOST" "GH_USER=$GH_USER" "C=$C" "TAGS=$TAGS" "PULL_SVCS=$CHANGE"

# 4. migrations with the new api image, before any restart
case " $CHANGE " in
  *" api "*) step "migrations (new api image)" 0 "$S_MIGRATE" "C=$C" "TAGS=$TAGS" ;;
esac

# 5. tags into plane.env
step "write the new tags into plane.env" 0 "$S_WRITE" "TAGS=$TAGS"

# 6. restart only the changed services
UP_SVCS=$(compose_services "$CHANGE")
step "up -d --no-deps $UP_SVCS" 0 "$S_UP" "C=$C" "UP_SVCS=$UP_SVCS"

# 7. health
CHECKS=
for s in $CHANGE; do
  case "$s" in web) CHECKS="$CHECKS web:300:/" ;; live) CHECKS="$CHECKS live:300:/live/health" ;; api) CHECKS="$CHECKS api:900:/api/instances/" ;; esac
done
step "health checks" 0 "$S_HEALTH" "CHECKS=${CHECKS# }" "HEALTH_BASE=$HEALTH_BASE" "HEALTH_HOST=$HEALTH_HOST"
HRC=$STEP_RC
if [ "$HRC" = 0 ]; then UPDATE_RESULT=ok; else UPDATE_RESULT=failed; fi
export UPDATE_RESULT

hook post

# 8. result
if [ "$DRY" = 1 ]; then echo "RESULT: dry-run only, nothing was run"; exit 0; fi
print_times
if [ "$HRC" != 0 ]; then
  echo "RESULT: update to $SHA applied ($CHANGE) but a health check FAILED. Nothing was rolled back." >&2
  echo "  logs:      (in the CT, in $PLANE_APP_DIR) $C logs --tail 100 $UP_SVCS" >&2
  echo "  roll back: PVE_HOST=... PLANE_CTID=... PLANE_APP_DIR=... fork/deploy/update.sh rollback" >&2
  exit 5
fi
echo "RESULT: update to $SHA done ($CHANGE). Undo with: fork/deploy/update.sh rollback"
exit 0
