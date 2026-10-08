#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# rollback.sh - one tested command per rollback level (RUNBOOK section 10).
#
# Runs on a workstation and reaches the Plane container the way the RUNBOOK
# does: ssh to the hypervisor, then `pct exec` into the container. It runs the
# same commands as the manual RUNBOOK steps, in the same order, and times each
# step. Nothing secret is read, printed or passed in an argument list; the
# compose `config` command is never used.
#
# Modes:
#   l1       both flags off, fork images kept. Generates
#            docker-compose.override.l1.yaml from the override with sed, checks
#            that exactly the 5 flag lines changed (the sed check; stops with
#            exit 2 and starts nothing if not), then `up -d api worker live`.
#   l2       stock images. Checks that the stock images (backend, frontend, space, admin, live,
#            proxy: every image that uses APP_RELEASE) exist locally, then
#            `up -d --pull never --wait --wait-timeout 60` from the upstream
#            compose file alone, lists services and images, and exits 2 if any
#            still shows a localhost/plane-fork- image.
#   forward  roll forward: `up -d` with the normal override, check that the five
#            fork services run the fork tag for FORK_N, then delete the L1 file.
#
# Required environment (operator supplied, no defaults):
#   PVE_HOST        ssh target of the hypervisor
#   PLANE_CTID      container id on the hypervisor (numeric)
#   PLANE_APP_DIR   absolute path of the plane-app directory in the container
#   STOCK_RELEASE   (l2 only) tag of the stock images running before the deploy
#   FORK_N          (forward only) fork build number
#
# Usage: rollback.sh [--dry-run] l1|l2|forward
#   --dry-run  print every command that would run; change nothing, connect nowhere.
#
# Idempotent: l1 regenerates its file from the untouched override and `up -d`
# is a no-op when nothing changed; forward uses `rm -f`.
#
# Exit status: 0 ok, 1 usage or prerequisite error, 2 a check failed (sed check,
# missing stock image, wrong images after forward), 3 a remote command failed.
set -u

usage() { echo "usage: rollback.sh [--dry-run] l1|l2|forward" >&2; exit 1; }

DRY=0
MODE=
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    l1|l2|forward) [ -z "$MODE" ] || usage; MODE=$a ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage

die() { echo "error: $*" >&2; exit 1; }
: "${PVE_HOST:=}" "${PLANE_CTID:=}" "${PLANE_APP_DIR:=}" "${STOCK_RELEASE:=}" "${FORK_N:=}"
[ -n "$PVE_HOST" ] && [ -n "$PLANE_CTID" ] && [ -n "$PLANE_APP_DIR" ] || die "set PVE_HOST, PLANE_CTID and PLANE_APP_DIR"
case "$PVE_HOST" in -*|*[!A-Za-z0-9._@:-]*) die "PVE_HOST has unexpected characters" ;; esac
case "$PLANE_CTID" in *[!0-9]*) die "PLANE_CTID must be numeric" ;; esac
case "$PLANE_APP_DIR" in /*) ;; *) die "PLANE_APP_DIR must be an absolute path" ;; esac
case "$PLANE_APP_DIR" in *[!A-Za-z0-9._/-]*) die "PLANE_APP_DIR has unexpected characters" ;; esac
if [ "$MODE" = l2 ]; then
  [ -n "$STOCK_RELEASE" ] || die "l2 needs STOCK_RELEASE (tag of the stock images, from the inspection)"
  case "$STOCK_RELEASE" in *[!A-Za-z0-9._-]*) die "STOCK_RELEASE has unexpected characters" ;; esac
fi
if [ "$MODE" = forward ]; then
  [ -n "$FORK_N" ] || die "forward needs FORK_N"
  case "$FORK_N" in *[!0-9]*) die "FORK_N must be numeric" ;; esac
fi

# Remote scripts (POSIX sh, run in the container, cwd = PLANE_APP_DIR).
read -r -d '' S_L1_GEN <<'EOF'
cd "$APP_DIR" || { echo "STOP: cannot enter the app dir"; exit 2; }
[ -f docker-compose.override.yaml ] || { echo "STOP: docker-compose.override.yaml not found"; exit 2; }
sed -e 's/LIVE_EVENTS_ENABLED: "1"/LIVE_EVENTS_ENABLED: "0"/' \
    -e 's/PAGES_API_ENABLED: "1"/PAGES_API_ENABLED: "0"/' \
    docker-compose.override.yaml > docker-compose.override.l1.yaml
off=$(grep -cE '^ +(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): "0"$' docker-compose.override.l1.yaml)
on=$(grep -cE '^ +(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): ' docker-compose.override.l1.yaml | tr -d ' ')
left=$(grep -cE '^ +(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): .*1' docker-compose.override.l1.yaml)
if [ "$off" = 5 ] && [ "$on" = 5 ] && [ "$left" = 0 ]; then
  echo "sed check ok: 5 flag lines set to \"0\", none left on"
else
  echo "STOP: expected exactly 5 flag lines set to \"0\" (3 LIVE_EVENTS_ENABLED + 2 PAGES_API_ENABLED) and none left on; got off=$off on=$on left=$left. Nothing was started; edit docker-compose.override.l1.yaml by hand and recheck."
  exit 2
fi
EOF

read -r -d '' S_L1_UP <<'EOF'
cd "$APP_DIR" || exit 2
docker compose -f docker-compose.yaml -f docker-compose.override.l1.yaml --env-file plane.env up -d api worker live
EOF

read -r -d '' S_L2_CHECK <<'EOF'
cd "$APP_DIR" || exit 2
missing=
for img in plane-backend plane-frontend plane-space plane-admin plane-live plane-proxy; do
  ids=$(docker image ls -q "makeplane/$img:$STOCK_RELEASE")
  [ -n "$ids" ] || missing="$missing makeplane/$img:$STOCK_RELEASE"
done
if [ -z "$missing" ]; then
  echo "stock images present at $STOCK_RELEASE: plane-backend plane-frontend plane-space plane-admin plane-live plane-proxy"
else
  echo "STOP: not in the local store:$missing; --pull never would fail halfway. Nothing was changed."
  exit 2
fi
EOF

read -r -d '' S_L2_UP <<'EOF'
cd "$APP_DIR" || exit 2
APP_RELEASE=$STOCK_RELEASE docker compose -f docker-compose.yaml --env-file plane.env up -d --pull never --wait --wait-timeout 60
EOF

read -r -d '' S_L2_PS <<'EOF'
cd "$APP_DIR" || exit 2
APP_RELEASE=$STOCK_RELEASE docker compose -f docker-compose.yaml --env-file plane.env ps --format '{{.Service}} {{.Image}}'
EOF

read -r -d '' S_FWD_UP <<'EOF'
cd "$APP_DIR" || exit 2
docker compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env up -d
EOF

read -r -d '' S_FWD_PS <<'EOF'
cd "$APP_DIR" || exit 2
docker compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env ps --format '{{.Service}} {{.Image}}'
EOF

read -r -d '' S_FWD_RM <<'EOF'
cd "$APP_DIR" || exit 2
rm -f docker-compose.override.l1.yaml
EOF

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

# sq <text>: POSIX single-quote text for the remote shell.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

now() { if [ -n "${EPOCHREALTIME:-}" ]; then echo "${EPOCHREALTIME/[.,]/}" | cut -c1-16; else echo "$(date +%s)000000"; fi; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
OUT=
LAST_SECS=0
TOTAL_START=$(now)

# step <label> <script> [VAR=value...]: run one remote script, time it, stop on failure.
step() {
  local label=$1 script=$2 rc t0 t1
  shift 2
  local remote
  remote="pct exec $PLANE_CTID -- env APP_DIR=$PLANE_APP_DIR"
  [ "$MODE" = l2 ] && remote="$remote STOCK_RELEASE=$STOCK_RELEASE"
  remote="$remote sh -c $(sq "$script")"
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] $MODE: $label"
    echo "+ ssh ${SSH_OPTS[*]} $PVE_HOST"
    echo "  remote command, sent as one argument:"
    printf '%s\n' "$remote" | sed 's/^/    /'
    OUT=
    return 0
  fi
  echo "== $MODE: $label"
  t0=$(now)
  # shellcheck disable=SC2029  # expanding the command on the client side is intended
  ssh "${SSH_OPTS[@]}" "$PVE_HOST" "$remote" </dev/null 2>&1 | tee "$TMP"
  rc=${PIPESTATUS[0]}
  t1=$(now)
  OUT=$(<"$TMP")
  LAST_SECS=$(( (t1 - t0) / 1000000 ))
  printf 'TIME %s: %s.%03d s\n' "$label" "$(( (t1 - t0) / 1000000 ))" "$(( ((t1 - t0) / 1000) % 1000 ))"
  if [ "$rc" != 0 ]; then
    if [ "$rc" = 2 ]; then
      echo "RESULT: $MODE stopped, a check failed; no further steps were run" >&2
      exit 2
    fi
    echo "RESULT: $MODE failed in step '$label' (rc=$rc); no further steps were run" >&2
    exit 3
  fi
}

finish() {
  if [ "$DRY" = 1 ]; then
    echo "RESULT: dry-run only, nothing was run"
  else
    local t=$(( ($(now) - TOTAL_START) / 1000000 ))
    echo "TIME total: $t s"
    echo "RESULT: $MODE done"
  fi
}

case "$MODE" in
  l1)
    step "generate L1 file and sed check" "$S_L1_GEN"
    step "up -d api worker live (L1 file)" "$S_L1_UP"
    ;;
  l2)
    step "check stock image exists" "$S_L2_CHECK"
    step "up -d stock images" "$S_L2_UP"
    if [ "$DRY" = 0 ] && [ "$LAST_SECS" -gt 60 ]; then
      echo "WARN: L2 up took ${LAST_SECS} s, over the 60 s target; record it and tell the owner"
    fi
    step "list services and images" "$S_L2_PS"
    if [ "$DRY" = 1 ]; then
      echo "[dry-run] l2: check that no service shows a localhost/plane-fork- image"
    elif printf '%s\n' "$OUT" | grep -q 'localhost/plane-fork-'; then
      echo "STOP: a service still runs a fork image after L2; do not report L2 done, escalate (RUNBOOK L3)" >&2
      exit 2
    else
      echo "image check ok: no fork image is running"
    fi
    echo "NEXT: ask users to hard-reload (RUNBOOK section 9)"
    ;;
  forward)
    step "up -d with the normal override" "$S_FWD_UP"
    step "list services and images" "$S_FWD_PS"
    if [ "$DRY" = 1 ]; then
      echo "[dry-run] forward: check web, live, api, worker, beat-worker run localhost/plane-fork-*:v1.4.2-live.$FORK_N"
    else
      bad=
      for pair in web:web live:live api:api worker:api beat-worker:api; do
        svc=${pair%%:*}
        img=${pair##*:}
        printf '%s\n' "$OUT" | grep -qxF "$svc localhost/plane-fork-$img:v1.4.2-live.$FORK_N" || bad="$bad $svc"
      done
      if [ -n "$bad" ]; then
        echo "STOP: not on the fork tag v1.4.2-live.$FORK_N:$bad. The L1 file was kept; rerun forward once the override is in place (never use setup.sh)." >&2
        exit 2
      fi
      echo "image check ok: five services on v1.4.2-live.$FORK_N"
    fi
    step "delete the L1 file" "$S_FWD_RM"
    echo "NEXT: smoke tests (RUNBOOK section 7)"
    ;;
esac
finish
exit 0
