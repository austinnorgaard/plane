#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# inspect.sh - READ-ONLY pre-deploy inspection of a Plane container.
#
# Runs on the hypervisor and reaches the Plane container with `pct exec`.
# It changes nothing, restarts nothing, writes nothing, and never kills a
# process. Secret values are never printed and never placed in an argument
# list: LIVE_SERVER_SECRET_KEY is read and hashed inside the container and only
# the words match / no-match / empty / unset come back.
#
# Required environment (operator supplied, no defaults):
#   PLANE_CTID      container id on the hypervisor
#   PLANE_APP_DIR   directory holding the compose file and plane.env
#
# Usage (from a workstation):
#   ssh "$PVE_HOST" "PLANE_CTID=$PLANE_CTID PLANE_APP_DIR=$PLANE_APP_DIR bash -s" < inspect.sh
#   ssh "$PVE_HOST" "PLANE_CTID=$PLANE_CTID PLANE_APP_DIR=$PLANE_APP_DIR bash -s -- --dry-run" < inspect.sh
#
# Exit status: 0 all clear, 1 usage or prerequisite error, 2 one or more STOP lines.
set -u

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "") ;;
  -h|--help) sed -n '2,24p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: inspect.sh [--dry-run]" >&2; exit 1 ;;
esac

: "${PLANE_CTID:=}"
: "${PLANE_APP_DIR:=}"
if [ -z "$PLANE_CTID" ] || [ -z "$PLANE_APP_DIR" ]; then
  echo "error: set PLANE_CTID and PLANE_APP_DIR" >&2
  exit 1
fi
case "$PLANE_CTID" in *[!0-9]*) echo "error: PLANE_CTID must be numeric" >&2; exit 1 ;; esac
case "$PLANE_APP_DIR" in
  /*) ;;
  *) echo "error: PLANE_APP_DIR must be an absolute path" >&2; exit 1 ;;
esac
case "$PLANE_APP_DIR" in *[!A-Za-z0-9._/-]*) echo "error: PLANE_APP_DIR has unexpected characters" >&2; exit 1 ;; esac

exec 3>&1
STOPS=0
stop() { echo "STOP: $*"; STOPS=$((STOPS + 1)); }
warn() { echo "WARN: $*"; }

# ct_sh <script> [args...]: run a POSIX sh script inside the container.
# The script text never contains a secret; values stay inside the container.
ct_sh() {
  local script=$1
  shift
  if [ "$DRY" = 1 ]; then
    printf '+ pct exec %s -- sh -c %q inspect' "$PLANE_CTID" "$script" >&3
    printf ' %q' "$@" >&3
    printf '\n' >&3
    return 0
  fi
  pct exec "$PLANE_CTID" -- sh -c "$script" inspect "$@"
}

read -r -d '' S_COMPOSE <<'EOF'
d=$1
[ -d "$d" ] || { echo "app_dir=missing"; exit 0; }
for f in docker-compose.yaml docker-compose.yml compose.yaml compose.yml; do
  [ -f "$d/$f" ] || continue
  echo "compose_file=$f"
  awk '/^services:/{s=1;next} /^[^ #]/{s=0}
       s && /^  [A-Za-z0-9_-]+:[ ]*$/ {svc=$1; sub(":","",svc)}
       s && svc ~ /^(web|live|api|worker|beat-worker)$/ && /^    image:/ {print "image." svc "=" $2}' "$d/$f"
  echo "compose_mentions_LIVE_BASE_URL=$(grep -c 'LIVE_BASE_URL' "$d/$f")"
done
EOF

read -r -d '' S_WEBURL <<'EOF'
f=$1/plane.env
[ -r "$f" ] || { echo "plane_env=unreadable"; exit 0; }
echo "plane_env=readable"
line=$(grep -m1 '^WEB_URL=' "$f" | tr -d '\r')
if [ -z "$line" ]; then echo "WEB_URL=unset"; else echo "WEB_URL=${line#*=}"; fi
if grep -q '^LIVE_BASE_URL=' "$f"; then echo "plane_env.LIVE_BASE_URL=set"; else echo "plane_env.LIVE_BASE_URL=unset"; fi
EOF

# The secret is read, hashed and compared here; only a word is printed.
read -r -d '' S_SECRET <<'EOF'
f=$1/plane.env
[ -r "$f" ] || { echo "secret=unreadable"; exit 0; }
line=$(grep -m1 '^LIVE_SERVER_SECRET_KEY=' "$f" | tr -d '\r') || true
[ -n "$line" ] || { echo "secret=unset"; exit 0; }
v=${line#*=}
v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
[ -n "$v" ] || { echo "secret=empty"; exit 0; }
h=$(printf '%s' "$v" | sha256sum | cut -d' ' -f1)
p=$(printf '%s' 'change-this-key-on-deployment' | sha256sum | cut -d' ' -f1)
if [ "$h" = "$p" ]; then echo "secret=match"; else echo "secret=no-match"; fi
EOF

# Names only: values are cut away before grep sees them.
read -r -d '' S_SVCENV <<'EOF'
ids=$(docker ps -q --filter "label=com.docker.compose.service=$1" 2>/dev/null)
[ -n "$ids" ] || { echo "not-running"; exit 0; }
r=unset
for id in $ids; do
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" | cut -d= -f1 | grep -qx LIVE_BASE_URL && r=set
done
echo "$r"
EOF

read -r -d '' S_IMAGE <<'EOF'
docker ps --filter "label=com.docker.compose.service=$1" --format '{{.Image}}' 2>/dev/null | sort -u | tr '\n' ' '
echo
EOF

read -r -d '' S_REDIS <<'EOF'
o=$(docker ps --filter "label=com.docker.compose.service=plane-redis" --format '{{.Ports}}' 2>/dev/null)
[ -n "$(docker ps -q --filter 'label=com.docker.compose.service=plane-redis' 2>/dev/null)" ] || { echo "not-running"; exit 0; }
case "$o" in *"->"*) echo "publishes-ports" ;; *) echo "no-published-ports" ;; esac
EOF

read -r -d '' S_DISK <<'EOF'
for p in "$1" /var/lib/docker; do
  [ -d "$p" ] || continue
  df -hP "$p" | awk -v p="$p" 'NR==2{print p ": size=" $2 " used=" $3 " avail=" $4 " use=" $5}'
done
EOF

kv() { # kv <key> <text>: value of key=value line
  printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n1
}

echo "== inspect.sh (read-only) =="
[ "$DRY" = 1 ] && echo "dry-run: printing commands, running nothing"

if [ "$DRY" = 0 ]; then
  command -v pct >/dev/null 2>&1 || { echo "error: pct not found (run this on the hypervisor)" >&2; exit 1; }
  st=$(pct status "$PLANE_CTID" 2>&1) || { echo "error: pct status failed" >&2; exit 1; }
  case "$st" in *running*) ;; *) echo "error: container is not running ($st)" >&2; exit 1 ;; esac
else
  echo "+ pct status $PLANE_CTID"
fi

echo "-- compose file and images --"
out=$(ct_sh "$S_COMPOSE" "$PLANE_APP_DIR")
[ "$DRY" = 1 ] || printf '%s\n' "$out"
if [ "$DRY" = 0 ] && ! printf '%s\n' "$out" | grep -q '^compose_file='; then
  warn "no compose file found in PLANE_APP_DIR"
fi

echo "-- WEB_URL (plane.env, non-secret URL) --"
out=$(ct_sh "$S_WEBURL" "$PLANE_APP_DIR")
[ "$DRY" = 1 ] || printf '%s\n' "$out"
plane_env_lbu=$(kv 'plane_env.LIVE_BASE_URL' "$out")

echo "-- LIVE_SERVER_SECRET_KEY (word only) --"
out=$(ct_sh "$S_SECRET" "$PLANE_APP_DIR")
[ "$DRY" = 1 ] || printf '%s\n' "$out"
secret=$(kv secret "$out")
if [ "$DRY" = 0 ]; then
  case "$secret" in
    no-match) ;;
    match) stop "LIVE_SERVER_SECRET_KEY is the shipped placeholder; rotating it is an owner decision, escalate" ;;
    empty) stop "LIVE_SERVER_SECRET_KEY is empty; escalate" ;;
    unset) stop "LIVE_SERVER_SECRET_KEY is not defined in plane.env; escalate" ;;
    *) stop "LIVE_SERVER_SECRET_KEY could not be checked ($secret); escalate" ;;
  esac
fi

echo "-- LIVE_BASE_URL set? (names only; running container env and plane.env) --"
[ "$DRY" = 1 ] || echo "plane.env: ${plane_env_lbu:-n/a}"
for svc in api worker beat-worker; do
  r=$(ct_sh "$S_SVCENV" "$svc")
  [ "$DRY" = 1 ] || echo "$svc: ${r:-n/a}"
  if [ "$DRY" = 0 ] && [ "$r" = set ] && { [ "$svc" = worker ] || [ "$svc" = beat-worker ]; }; then
    stop "LIVE_BASE_URL is set on $svc; the copy_s3_object live sync would already be active; escalate"
  fi
done
if [ "$DRY" = 0 ] && [ "$plane_env_lbu" = set ]; then
  warn "plane.env defines LIVE_BASE_URL; check that no service receives it other than api"
fi

echo "-- running images --"
for svc in web live api worker beat-worker; do
  r=$(ct_sh "$S_IMAGE" "$svc")
  [ "$DRY" = 1 ] || echo "$svc: ${r:-n/a}"
done

echo "-- plane-redis published ports --"
r=$(ct_sh "$S_REDIS")
[ "$DRY" = 1 ] || echo "plane-redis: ${r:-n/a}"

echo "-- snapshots --"
if [ "$DRY" = 1 ]; then
  echo "+ pct listsnapshot $PLANE_CTID"
else
  if pct listsnapshot "$PLANE_CTID" >/dev/null 2>&1; then echo "listsnapshot: works"; else echo "listsnapshot: FAILED"; warn "snapshots unavailable; the rollback plan needs them"; fi
fi

echo "-- free disk --"
ct_sh "$S_DISK" "$PLANE_APP_DIR"

echo "-- URLs --"
echo "Public and LAN URLs are not discoverable from here; record them as PUBLIC_URL and LAN_URL in the runbook."

if [ "$STOPS" -gt 0 ]; then
  echo "RESULT: $STOPS STOP line(s); do not deploy, escalate"
  exit 2
fi
echo "RESULT: no STOP lines"
exit 0
