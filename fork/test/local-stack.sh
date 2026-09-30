#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# local-stack.sh - throwaway integration stack for the fork images, run headless
# on the machine that builds them (as root, in the podman host).
#
#   local-stack.sh up       generate fork/test/local-stack.env (if missing), start the
#                           stack, wait for it, create local-only test users, API keys,
#                           a project and one work item
#   local-stack.sh smoke    run the checks, print PASS/FAIL per check, exit non-zero on
#                           any FAIL; prints the browser steps that need a real browser
#   local-stack.sh down     stop the stack and remove its volumes
#   local-stack.sh patch-page <page_id> [html]
#                           PATCH a page with the member key (used by the manual steps)
#
# The stack is the stock upstream community compose file
# (deployments/cli/community/docker-compose.yml, v1.4.2) plus
# fork/deploy/docker-compose.override.yaml, with the fork images
# localhost/plane-fork-{web,live,api}:v1.4.2-live.${FORK_N}.
#
# Compose provider, first match wins: $COMPOSE_CMD, `podman compose` (only when it
# has a provider), docker-compose, podman-compose, `docker compose`. `podman compose`
# only works when a provider is installed (fork/SPIKE.md: none was installed on the
# build host). Recommended: the docker-compose v2 binary with DOCKER_HOST pointing at the
# podman socket; alternative: `pip install podman-compose`. See the PR for the commands.
#
# Settings (environment, all optional):
#   FORK_N                     image build number, default 1 (tag v1.4.2-live.1)
#   LOCAL_STACK_PORT           published http port on this machine, default 18080
#   LOCAL_STACK_TLS_PORT       published https port (unused by the stack), default 18443
#   LOCAL_STACK_MINIO_IMAGE    replace the upstream minio image (it may be unpullable)
#   COMPOSE_CMD                compose command, for example "podman-compose"
#   LOCAL_STACK_DIR            where env, state, report and generated files live
#                              (default: this directory)
#
# Files written next to this script (all gitignored, mode 600, throwaway values only):
#   local-stack.env      compose variables, incl. a random LIVE_SERVER_SECRET_KEY
#   local-stack.state    ids, API keys and session ids of the test users
#   local-stack.report   the last smoke report (PASS/FAIL lines only, no URLs)
#   local-stack.l1.yaml, local-stack.extra.yaml   generated compose overrides
# Secrets are never printed: only key names and PASS/FAIL.
# shellcheck disable=SC2015 # "cond && ok || bad": ok never fails
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
DIR=${LOCAL_STACK_DIR:-$HERE}
BASE_FILE=$REPO/deployments/cli/community/docker-compose.yml
OVERRIDE=$REPO/fork/deploy/docker-compose.override.yaml
ENV_FILE=$DIR/local-stack.env
STATE_FILE=$DIR/local-stack.state
REPORT_FILE=$DIR/local-stack.report
L1_FILE=$DIR/local-stack.l1.yaml
EXTRA_FILE=$DIR/local-stack.extra.yaml
WS_PROBE=${LOCAL_STACK_WS_PROBE:-$HERE/ws_probe.py}
PROJECT=${LOCAL_STACK_PROJECT:-plane-lu-local}
PORT=${LOCAL_STACK_PORT:-18080}
TLS_PORT=${LOCAL_STACK_TLS_PORT:-18443}
FORK_N=${FORK_N:-1}
WORKSPACE_SLUG=lu-local
MODE=fork
COMPOSE=${COMPOSE_CMD:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BODY=$TMP/body
umask 077

log() { printf '%s\n' "$*"; }
die() { printf 'local-stack: %s\n' "$*" >&2; exit 2; }

# ------------------------------------------------------------------ engine

detect_compose() {
  [ -n "$COMPOSE" ] && return 0
  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE="podman compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE="podman-compose"
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  else
    die "no compose provider found (tried: podman compose, docker-compose, podman-compose, docker compose). Install docker-compose or podman-compose."
  fi
}

# dc <compose args...>; MODE picks the file set: fork (base+override), l1 (base+l1), stock (base only)
dc() {
  local -a files
  case "$MODE" in
    stock) files=(-f "$BASE_FILE") ;;
    l1) files=(-f "$BASE_FILE" -f "$L1_FILE") ;;
    *) files=(-f "$BASE_FILE" -f "$OVERRIDE") ;;
  esac
  [ -f "$EXTRA_FILE" ] && files+=(-f "$EXTRA_FILE")
  # shellcheck disable=SC2086 # $COMPOSE is a command line ("podman compose") on purpose
  $COMPOSE -p "$PROJECT" --env-file "$ENV_FILE" "${files[@]}" "$@"
}

# ------------------------------------------------------------------ files

random_hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

envval() { [ -f "$ENV_FILE" ] && grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2-; }
stateval() { [ -f "$STATE_FILE" ] && grep -m1 "^$1=" "$STATE_FILE" | cut -d= -f2-; }

# Writes the env file unless one exists. An existing file is kept and reported; it is only
# replaced when REGEN=1 (up --regenerate-env).
gen_env() {
  if [ -f "$ENV_FILE" ] && [ "${REGEN:-0}" != 1 ]; then
    log "env: keeping existing $(basename "$ENV_FILE") (use 'up --regenerate-env' to replace it)"
    return 0
  fi
  local url=http://localhost:$PORT
  {
    echo "# Generated by local-stack.sh. Throwaway values for a local test stack only."
    echo "FORK_N=$FORK_N"
    echo "APP_RELEASE=v1.4.2"
    echo "APP_DOMAIN=localhost"
    echo "LISTEN_HTTP_PORT=$PORT"
    echo "LISTEN_HTTPS_PORT=$TLS_PORT"
    echo "SITE_ADDRESS=:80"
    echo "WEB_URL=$url"
    echo "CORS_ALLOWED_ORIGINS=$url"
    echo "LIVE_EVENTS_ALLOWED_ORIGINS=$url"
    echo "SECRET_KEY=$(random_hex)"
    echo "LIVE_SERVER_SECRET_KEY=$(random_hex)"
    echo "API_KEY_RATE_LIMIT=600/minute"
    echo "CERT_EMAIL="
    echo "CERT_ACME_CA=https://acme-v02.api.letsencrypt.org/directory"
    echo "CERT_ACME_DNS="
    echo "TRUSTED_PROXIES=0.0.0.0/0"
  } >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "env: wrote $(basename "$ENV_FILE") (names only: FORK_N APP_RELEASE LISTEN_HTTP_PORT WEB_URL LIVE_EVENTS_ALLOWED_ORIGINS SECRET_KEY LIVE_SERVER_SECRET_KEY ...)"
}

gen_extra() {
  rm -f "$EXTRA_FILE"
  [ -n "${LOCAL_STACK_MINIO_IMAGE:-}" ] || return 0
  printf 'services:\n  plane-minio:\n    image: %s\n' "$LOCAL_STACK_MINIO_IMAGE" >"$EXTRA_FILE"
  log "extra: plane-minio image replaced by \$LOCAL_STACK_MINIO_IMAGE"
}

gen_l1() {
  sed -e 's/LIVE_EVENTS_ENABLED: "1"/LIVE_EVENTS_ENABLED: "0"/' \
    -e 's/PAGES_API_ENABLED: "1"/PAGES_API_ENABLED: "0"/' "$OVERRIDE" >"$L1_FILE"
}

# ------------------------------------------------------------------ http helpers

CODE=000
# req METHOD URL [API_KEY] [JSON_BODY] -> CODE, body in $BODY. The key goes through a
# header file, not the command line.
req() {
  local method=$1 url=$2 key=${3:-} data=${4:-}
  local -a args=(-sS -m 30 -o "$BODY" -w '%{http_code}' -X "$method")
  if [ -n "$key" ]; then
    printf 'X-API-Key: %s\n' "$key" >"$TMP/hdr"
    args+=(-H "@$TMP/hdr")
  fi
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
  : >"$BODY"
  CODE=$(curl "${args[@]}" "$url" 2>/dev/null) || CODE=000
  [ -n "$CODE" ] || CODE=000
}

jfield() { python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get(sys.argv[2],"") if isinstance(d,dict) else ""
except Exception:
    v=""
print(v if v is not None else "")' "$BODY" "$1"; }

# wait_code URL REGEX SECONDS: poll until the http status matches
wait_code() {
  local url=$1 re=$2 secs=$3 code i
  for ((i = 0; i < secs; i += 5)); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null) || code=000
    [[ $code =~ $re ]] && return 0
    sleep 5
  done
  return 1
}

# wait_settled URL KEY SECONDS: poll until the status is not a restart artefact
wait_settled() {
  local url=$1 key=$2 secs=$3 i
  for ((i = 0; i < secs; i += 5)); do
    req GET "$url" "$key"
    [[ $CODE =~ ^(000|502|503|504)$ ]] || return 0
    sleep 5
  done
  return 1
}

# ------------------------------------------------------------------ up

image_exists() {
  if command -v podman >/dev/null 2>&1; then
    podman image exists "$1"
  elif command -v docker >/dev/null 2>&1; then
    docker image inspect "$1" >/dev/null 2>&1
  else
    return 0
  fi
}

SEED_USERS=$(
  cat <<'PY'
from django.conf import settings
from django.test import Client
from django.utils.crypto import get_random_string
from plane.db.models import Profile, User, Workspace, WorkspaceMember
from plane.db.models.api import APIToken

SLUG = "lu-local"
out = {"WORKSPACE_SLUG": SLUG}
users = {}
for name in ("admin", "member", "guest", "nonmember"):
    email = "lu-%s@example.test" % name
    password = get_random_string(24)
    user = User.objects.filter(email=email).first()
    if user is None:
        user = User(email=email, username="lu_" + name, first_name="LU", last_name=name, is_active=True, is_email_verified=True)
    user.set_password(password)
    user.save()
    Profile.objects.get_or_create(user=user, defaults={"is_onboarded": True})
    users[name] = user
    out[name.upper() + "_EMAIL"] = email
    out[name.upper() + "_PASSWORD"] = password
ws = Workspace.objects.filter(slug=SLUG).first()
if ws is None:
    ws = Workspace.objects.create(name="LU Local", slug=SLUG, owner=users["admin"])
for name, role in (("admin", 20), ("member", 15), ("guest", 5)):
    WorkspaceMember.objects.update_or_create(workspace=ws, member=users[name], defaults={"role": role, "is_active": True})
for name, user in users.items():
    token = APIToken.objects.filter(user=user, label="lu-local").first()
    if token is None:
        token = APIToken.objects.create(user=user, label="lu-local")
    out[name.upper() + "_KEY"] = token.token
    client = Client()
    client.force_login(user)
    out[name.upper() + "_SESSION"] = client.cookies[settings.SESSION_COOKIE_NAME].value
try:
    from plane.license.models import Instance, InstanceAdmin

    instance = Instance.objects.last()
    if instance is not None:
        instance.is_setup_done = True
        instance.save()
        InstanceAdmin.objects.get_or_create(user=users["admin"], instance=instance, defaults={"role": 20})
except Exception as exc:
    print("NOTE instance flags not set: %s" % type(exc).__name__)
for key, value in out.items():
    print("STATE %s=%s" % (key, value))
PY
)

SEED_MEMBERS=$(
  cat <<'PY'
from plane.db.models import Project, ProjectMember, User

project = Project.objects.get(pk=PROJECT_ID)
for name, role in (("member", 15), ("guest", 5)):
    user = User.objects.get(email="lu-%s@example.test" % name)
    ProjectMember.objects.update_or_create(
        project=project, member=user, defaults={"role": role, "is_active": True, "workspace": project.workspace}
    )
print("STATE MEMBERS_SEEDED=1")
PY
)

state_set() { # state_set KEY VALUE
  grep -v "^$1=" "$STATE_FILE" 2>/dev/null >"$TMP/state.new" || true
  printf '%s=%s\n' "$1" "$2" >>"$TMP/state.new"
  cat "$TMP/state.new" >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

run_seed() { # run_seed SCRIPT -> appends STATE lines to the state file
  local script=$1 out i
  for ((i = 0; i < 30; i++)); do
    if out=$(dc exec -T api python manage.py shell -c "$script" 2>"$TMP/seed.err"); then
      local line
      while IFS= read -r line; do
        line=${line%$'\r'}
        [[ $line == "STATE "* ]] || continue
        line=${line#STATE }
        state_set "${line%%=*}" "${line#*=}"
      done <<<"$out"
      return 0
    fi
    sleep 10
  done
  log "seed failed; last error class: $(tail -n 1 "$TMP/seed.err" | cut -c1-120)"
  return 1
}

cmd_up() {
  [ "${1:-}" = "--regenerate-env" ] && REGEN=1
  [ -f "$BASE_FILE" ] || die "missing $BASE_FILE"
  [ -f "$OVERRIDE" ] || die "missing $OVERRIDE (this script needs the deploy override from the deploy runbook change)"
  detect_compose
  log "compose provider: $COMPOSE"
  gen_env
  gen_extra
  gen_l1
  local url
  url=http://localhost:$(envval LISTEN_HTTP_PORT)
  MODE=fork
  dc config -q >/dev/null 2>"$TMP/cfg.err" || { log "compose config failed:"; head -n 5 "$TMP/cfg.err" >&2; return 1; }
  log "compose config: ok"
  local svc missing=0
  for svc in web live api; do
    image_exists "localhost/plane-fork-$svc:v1.4.2-live.$(envval FORK_N)" || { log "missing image localhost/plane-fork-$svc:v1.4.2-live.$(envval FORK_N); build or load it first"; missing=1; }
  done
  [ "$missing" -eq 0 ] || return 1
  dc up -d || { log "compose up failed"; return 1; }
  wait_code "$url/api/instances/" '^200$' 300 || { log "api did not answer within 300 s"; return 1; }
  wait_code "$url/live/health" '^200$' 120 || { log "live health did not answer within 120 s"; return 1; }
  log "stack is answering"

  : >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
  run_seed "$SEED_USERS" || return 1
  local admin_key
  admin_key=$(stateval ADMIN_KEY)
  [ -n "$admin_key" ] || { log "seed produced no admin key"; return 1; }
  local api=$url/api/v1/workspaces/$WORKSPACE_SLUG

  req POST "$api/projects/" "$admin_key" '{"name":"LU Smoke","identifier":"LUS"}'
  local pid
  if [ "$CODE" = 201 ]; then
    pid=$(jfield id)
  else
    req GET "$api/projects/" "$admin_key"
    pid=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for p in d.get("results",[]):
    if p.get("identifier")=="LUS":
        print(p["id"])
        break' "$BODY" 2>/dev/null)
  fi
  [ -n "$pid" ] || { log "could not create or find the project (http $CODE)"; return 1; }
  state_set PROJECT_ID "$pid"
  run_seed "PROJECT_ID = \"$pid\"
$SEED_MEMBERS" || return 1

  req POST "$api/projects/$pid/issues/" "$admin_key" '{"name":"lu smoke issue"}'
  local iid
  iid=$(jfield id)
  [ -n "$iid" ] || { log "could not create the work item (http $CODE)"; return 1; }
  state_set ISSUE_ID "$iid"
  log "seeded: users admin/member/guest/nonmember, API keys, project, work item (values in $(basename "$STATE_FILE"))"
  log "next: $0 smoke"
}

# ------------------------------------------------------------------ smoke

PASS_N=0
FAIL_N=0
report() { printf '%s\n' "$1" | tee -a "$REPORT_FILE"; }
ok() { PASS_N=$((PASS_N + 1)); report "PASS $1"; }
bad() { FAIL_N=$((FAIL_N + 1)); report "FAIL $1 ($2)"; }
expect_code() { # expect_code NAME WANT_REGEX
  if [[ $CODE =~ $2 ]]; then ok "$1"; else bad "$1" "http $CODE"; fi
}
probe() { # probe ARGS... -> one JSON line from ws_probe.py
  python3 "$WS_PROBE" "$@" 2>/dev/null || echo '{"error":"probe failed"}'
}
pj() { python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1]); v=d.get(sys.argv[2])
except Exception:
    v=None
print("" if v is None else (json.dumps(v) if isinstance(v,(list,dict)) else v))' "$1" "$2"; }

GUARD_SCRIPT=$(
  cat <<'PY'
import os, json, requests
base = "http://live:3000/live/fork/pages/00000000-0000-4000-8000-000000000000/loaded"
rebase = "http://live:3000/live/fork/pages/rebase"
key = {"live-server-secret-key": os.environ["LIVE_SERVER_SECRET_KEY"]}
ctype = {"Content-Type": "application/vnd.plane-fork.rebase+json"}
body = json.dumps({"base_binary": "AAAA", "description_html": "<p>x</p>"})
def code(method, url, **kw):
    try:
        return requests.request(method, url, timeout=5, **kw).status_code
    except Exception:
        return 0
try:
    keyed = requests.get(base, headers=key, timeout=5)
    keyed_code, keyed_body = keyed.status_code, keyed.text.strip()
except Exception:
    keyed_code, keyed_body = 0, ""
print("GUARD loaded_nokey=%s loaded_key=%s loaded_xff=%s rebase_nokey=%s loaded_body=%s" % (
    code("GET", base),
    keyed_code,
    code("GET", base, headers=dict(key, **{"X-Forwarded-For": "client"})),
    code("POST", rebase, headers=ctype, data=body),
    keyed_body.replace(" ", ""),
))
PY
)

FORK_SVCS=(web live api worker beat-worker)
L1_SVCS=(api worker live)

# switch MODE SERVICE...: apply the file set MODE to the named services. --force-recreate
# makes the result independent of the provider (podman-compose does not recreate a
# container whose configuration changed); --no-deps keeps the databases untouched.
switch() {
  MODE=$1
  shift
  dc up -d --force-recreate --no-deps "$@" >/dev/null 2>&1
}

# settle LABEL URL API KEY SECONDS: wait for api and live after a switch; a timeout is a FAIL
settle() {
  wait_settled "$3/pages/" "$4" "$5" || bad "$1: api did not answer within $5 s" "timeout"
  wait_code "$2/live/health" '^200$' 90 || bad "$1: live health did not answer within 90 s" "timeout"
}

# running_images: images of the running containers of this compose project, one per line
running_images() {
  local eng label out
  for eng in podman docker; do
    command -v "$eng" >/dev/null 2>&1 || continue
    for label in io.podman.compose.project com.docker.compose.project; do
      out=$("$eng" ps --filter "label=$label=$PROJECT" --format '{{.Image}}' 2>/dev/null | tr -d '\r' | grep -v '^$')
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
      fi
    done
  done
  return 1
}

IMG_TOTAL=0
IMG_FORK=0
count_images() {
  local list
  list=$(running_images) || list=""
  IMG_TOTAL=$(printf '%s' "$list" | grep -c .)
  IMG_FORK=$(printf '%s' "$list" | grep -c 'plane-fork-')
}
# image_check NAME WANT_FORK: FAIL when no image list is available, so it never passes vacuously
image_check() {
  if [ "$IMG_TOTAL" -lt 5 ]; then
    bad "$1" "image list unavailable (saw $IMG_TOTAL running containers)"
  elif [ "$IMG_FORK" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "found $IMG_FORK fork images"
  fi
}

cmd_smoke() {
  [ -f "$STATE_FILE" ] || die "no $(basename "$STATE_FILE"); run '$0 up' first"
  detect_compose
  MODE=fork
  : >"$REPORT_FILE"
  local url api pid iid mk gk nk ws origin
  url=http://localhost:$(envval LISTEN_HTTP_PORT)
  ws=ws://localhost:$(envval LISTEN_HTTP_PORT)/live/events
  origin=$(envval WEB_URL)
  pid=$(stateval PROJECT_ID)
  iid=$(stateval ISSUE_ID)
  mk=$(stateval MEMBER_KEY)
  gk=$(stateval GUEST_KEY)
  nk=$(stateval NONMEMBER_KEY)
  api=$url/api/v1/workspaces/$WORKSPACE_SLUG/projects/$pid
  [ -n "$pid" ] && [ -n "$mk" ] || die "state file is incomplete; run '$0 down' then '$0 up'"
  local foreign=http://foreign.example.invalid

  report "SMOKE REPORT fork tag v1.4.2-live.$(envval FORK_N), compose provider: $COMPOSE"

  report "-- events socket"
  local out
  out=$(WS_COOKIE="session-id=$(stateval MEMBER_SESSION)" probe --mode connect --url "$ws" --origin "$foreign" --timeout 8)
  [ "$(pj "$out" close)" = 4403 ] && ok "foreign Origin rejected (close 4403)" || bad "foreign Origin rejected (close 4403)" "close=$(pj "$out" close) http=$(pj "$out" http_status)"
  out=$(WS_COOKIE="session-id=$(stateval MEMBER_SESSION)" probe --mode connect --url "$ws" --origin "$origin" --slug "$WORKSPACE_SLUG" --project "$pid")
  [[ "$(pj "$out" subscribed)" == *"$pid"* ]] && ok "member subscribe granted from the allowed Origin" || bad "member subscribe granted from the allowed Origin" "$(pj "$out" error) close=$(pj "$out" close)"
  out=$(WS_COOKIE="session-id=$(stateval GUEST_SESSION)" probe --mode connect --url "$ws" --origin "$origin" --slug "$WORKSPACE_SLUG" --project "$pid")
  [[ "$(pj "$out" denied)" == *"$pid"* ]] && ok "guest subscribe denied" || bad "guest subscribe denied" "$(pj "$out" error) close=$(pj "$out" close)"
  out=$(WS_COOKIE="session-id=$(stateval NONMEMBER_SESSION)" probe --mode connect --url "$ws" --origin "$origin" --slug "$WORKSPACE_SLUG" --project "$pid")
  [[ "$(pj "$out" denied)" == *"$pid"* ]] && ok "non-member subscribe denied" || bad "non-member subscribe denied" "$(pj "$out" error) close=$(pj "$out" close)"

  report "-- API-key PATCH delivers a frame"
  out=$(WS_COOKIE="session-id=$(stateval MEMBER_SESSION)" WS_API_KEY="$mk" probe --mode latency --url "$ws" --origin "$origin" \
    --slug "$WORKSPACE_SLUG" --project "$pid" --issue "$iid" --patch-url "$api/issues/$iid/" \
    --patch-body "{\"name\":\"lu smoke issue $RANDOM\"}" --timeout 12)
  local lat
  lat=$(pj "$out" latency)
  if [ "$(pj "$out" patch_status)" = 200 ] && [ -n "$lat" ] && python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])<=2.0 else 1)' "$lat"; then
    ok "issue PATCH with API key delivered a frame in ${lat}s (limit 2s)"
  else
    bad "issue PATCH with API key delivered a frame within 2s" "patch=$(pj "$out" patch_status) latency=${lat:-none}"
  fi

  report "-- pages API (never-opened page)"
  local page
  req POST "$api/pages/" "$mk" '{"name":"lu smoke page","description_html":"<p>lu-original</p>"}'
  expect_code "pages create (member)" '^201$'
  page=$(jfield id)
  if [ -n "$page" ]; then
    req GET "$api/pages/$page/" "$mk"
    if [ "$CODE" = 200 ] && grep -q 'lu-original' "$BODY"; then ok "pages GET returns the created body"; else bad "pages GET returns the created body" "http $CODE"; fi
    req PATCH "$api/pages/$page/" "$mk" '{"description_html":"<p>lu-changed</p>"}'
    expect_code "pages PATCH of a never-opened page" '^200$'
    req GET "$api/pages/$page/" "$mk"
    if [ "$CODE" = 200 ] && grep -q 'lu-changed' "$BODY" && ! grep -q 'lu-original' "$BODY"; then ok "pages GET shows the PATCHed body"; else bad "pages GET shows the PATCHed body" "http $CODE"; fi
    req PATCH "$api/pages/$page/" "$gk" '{"description_html":"<p>lu-guest</p>"}'
    expect_code "pages PATCH by guest refused" '^403$'
  else
    bad "pages GET/PATCH" "no page id from create"
  fi
  req GET "$api/pages/" "$gk"
  expect_code "pages list by guest" '^200$'
  req POST "$api/pages/" "$gk" '{"name":"lu guest page","description_html":"<p>x</p>"}'
  expect_code "pages create by guest refused" '^403$'
  req GET "$api/pages/" "$nk"
  expect_code "pages list by non-member refused" '^(403|404)$'

  report "-- live pages endpoints: 401 direct, 403 through the proxy"
  local g pid0=00000000-0000-4000-8000-000000000000
  g=$(dc exec -T api python -c "$GUARD_SCRIPT" 2>/dev/null | tr -d '\r' | grep '^GUARD ' | tail -n 1)
  gv() { printf '%s' "$g" | tr ' ' '\n' | grep -m1 "^$1=" | cut -d= -f2-; }
  [ "$(gv loaded_nokey)" = 401 ] && ok "direct live /loaded without key: 401" || bad "direct live /loaded without key: 401" "got $(gv loaded_nokey)"
  [ "$(gv rebase_nokey)" = 401 ] && ok "direct live /rebase without key: 401" || bad "direct live /rebase without key: 401" "got $(gv rebase_nokey)"
  [ "$(gv loaded_key)" = 200 ] && [ "$(gv loaded_body)" = '{"loaded":false}' ] && ok "direct live /loaded with key: 200 {loaded:false}" || bad "direct live /loaded with key: 200 {loaded:false}" "got $(gv loaded_key) $(gv loaded_body)"
  [ "$(gv loaded_xff)" = 403 ] && ok "direct live /loaded with X-Forwarded-For: 403" || bad "direct live /loaded with X-Forwarded-For: 403" "got $(gv loaded_xff)"
  req GET "$url/live/fork/pages/$pid0/loaded"
  expect_code "proxy /live/fork/pages/<id>/loaded without key: 403" '^403$'
  : >"$BODY"
  CODE=$(curl -sS -m 15 -o "$BODY" -w '%{http_code}' -X POST -H 'Content-Type: application/vnd.plane-fork.rebase+json' \
    --data '{"base_binary":"AAAA","description_html":"<p>x</p>"}' "$url/live/fork/pages/rebase" 2>/dev/null) || CODE=000
  expect_code "proxy /live/fork/pages/rebase without key: 403" '^403$'

  report "-- rollback L1 (both flags off)"
  gen_l1
  if switch l1 "${L1_SVCS[@]}"; then
    settle "L1" "$url" "$api" "$mk" 120
    req GET "$api/pages/" "$mk"
    expect_code "L1 pages API answers 404" '^404$'
    out=$(WS_COOKIE="session-id=$(stateval MEMBER_SESSION)" probe --mode connect --url "$ws" --origin "$origin" --slug "$WORKSPACE_SLUG" --project "$pid")
    [ "$(pj "$out" close)" = 4404 ] && ok "L1 events socket closes with 4404" || bad "L1 events socket closes with 4404" "close=$(pj "$out" close) http=$(pj "$out" http_status)"
    req PATCH "$api/issues/$iid/" "$mk" '{"name":"lu smoke issue l1"}'
    expect_code "L1 issue PATCH still works" '^200$'
  else
    bad "L1 apply" "compose up failed"
  fi
  if switch fork "${L1_SVCS[@]}"; then
    settle "roll forward after L1" "$url" "$api" "$mk" 120
    req GET "$api/pages/" "$mk"
    expect_code "roll forward after L1: pages API answers 200" '^200$'
  else
    bad "roll forward after L1" "compose up failed"
  fi

  report "-- rollback L2 (stock images)"
  MODE=fork
  count_images
  image_check "before L2: 5 services run fork images" 5
  if switch stock "${FORK_SVCS[@]}"; then
    settle "L2" "$url" "$api" "$mk" 180
    MODE=stock
    count_images
    image_check "L2: no service runs a fork image" 0
    req GET "$api/pages/" "$mk"
    expect_code "L2 pages API answers 404" '^404$'
    req PATCH "$api/issues/$iid/" "$mk" '{"name":"lu smoke issue l2"}'
    expect_code "L2 issue PATCH still works" '^200$'
    out=$(WS_COOKIE="session-id=$(stateval MEMBER_SESSION)" probe --mode connect --url "$ws" --origin "$origin" --slug "$WORKSPACE_SLUG" --project "$pid" --timeout 5)
    if [ "$(pj "$out" http_status)" != 101 ] || [ "$(pj "$out" close)" = 4404 ]; then ok "L2 events socket not available"; else bad "L2 events socket not available" "http=$(pj "$out" http_status) close=$(pj "$out" close)"; fi
  else
    bad "L2 apply" "compose up failed"
  fi
  if switch fork "${FORK_SVCS[@]}"; then
    settle "roll forward after L2" "$url" "$api" "$mk" 180
    req GET "$api/pages/" "$mk"
    expect_code "roll forward after L2: pages API answers 200" '^200$'
    count_images
    image_check "roll forward after L2: 5 services run fork images" 5
  else
    bad "roll forward after L2" "compose up failed"
  fi

  report "-- MCP page-path confirmation: NOT COVERED (optional PC step)"
  report "   observed api-log method and path templates (from this script's own calls):"
  dc logs --tail 400 api 2>/dev/null | tr -d '\r' | grep -o '"[A-Z]* /api/v1/[^ ]*pages[^ ]*' \
    | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g; s#/workspaces/[^/]+#/workspaces/<slug>#' | sort -u | while IFS= read -r l; do report "   $l"; done

  # a page for the browser steps
  local mpage=""
  req POST "$api/pages/" "$mk" '{"name":"lu manual page","description_html":"<p>lu-manual-original</p>"}'
  [ "$CODE" = 201 ] && mpage=$(jfield id)

  report ""
  report "SUMMARY: $PASS_N passed, $FAIL_N failed"
  print_manual "$mpage" "$pid"
  [ "$FAIL_N" -eq 0 ]
}

print_manual() {
  local mpage=$1 pid=$2
  report ""
  report "MANUAL STEPS (need a real browser; optional, run them on a machine that can open the local URL)"
  if [ -z "$mpage" ]; then
    report "  (could not create the manual page; skip)"
    return 0
  fi
  report "  1. Open the local URL (WEB_URL in $(basename "$ENV_FILE")) and sign in with email/password as the member:"
  report "     email and password are MEMBER_EMAIL and MEMBER_PASSWORD in $(basename "$STATE_FILE"). Do not paste them anywhere."
  report "  2. Open the page: <WEB_URL>/$WORKSPACE_SLUG/projects/$pid/pages/$mpage/  and leave the tab open for 5 s."
  report "  3. In a shell:  $0 patch-page $mpage     expected: 409 {\"error\": \"page is open in an editor; retry later\"}"
  report "  4. Close every tab of the page, wait 10 s, run step 3 again.   expected: 200"
  report "  5. Reopen the page.   expected: the text lu-manual-changed shows exactly once."
  report "  Record each result as PASS or FAIL in the PR comment."
}

cmd_patch_page() {
  local page=${1:-} html=${2:-'<p>lu-manual-changed</p>'}
  [ -n "$page" ] || die "usage: $0 patch-page <page_id> [html]"
  [ -f "$STATE_FILE" ] || die "no state file; run up first"
  local url pid mk body
  url=http://localhost:$(envval LISTEN_HTTP_PORT)
  pid=$(stateval PROJECT_ID)
  mk=$(stateval MEMBER_KEY)
  body=$(python3 -c 'import json,sys;print(json.dumps({"description_html":sys.argv[1]}))' "$html")
  req PATCH "$url/api/v1/workspaces/$WORKSPACE_SLUG/projects/$pid/pages/$page/" "$mk" "$body"
  local resp
  resp=$(head -c 300 "$BODY")
  printf '%s %s\n' "$CODE" "$resp"
}

# ------------------------------------------------------------------ down

cmd_down() {
  detect_compose
  [ -f "$ENV_FILE" ] || gen_env >/dev/null
  gen_l1
  MODE=fork
  local rc=0
  dc down -v --remove-orphans || rc=$?
  rm -f "$STATE_FILE" "$L1_FILE"
  if [ "$rc" -eq 0 ]; then log "stack removed with its volumes; state file deleted (env file kept)"; else log "compose down failed (rc=$rc)"; fi
  return "$rc"
}

# ------------------------------------------------------------------ main

usage() { sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local sub=${1:-help}
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    up) cmd_up "$@" ;;
    smoke) cmd_smoke "$@" ;;
    down) cmd_down "$@" ;;
    patch-page) cmd_patch_page "$@" ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
