#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# upgrade-rollback.sh - data safety test for upgrading stock v1.4.2 to the fork images and
# rolling back (QA-12). Runs on the local throwaway stack of local-stack.sh.
#
#   upgrade-rollback.sh run [--keep]
#       1. start the STOCK stack and seed data: users, API keys, two projects, work items with
#          comments and labels, a cycle, a module, pages with content
#       2. fingerprint the database (row counts of every table, content hashes of selected rows,
#          no secrets) and check the app
#       3. upgrade to the fork images (flags on), create data in the fork (pages through
#          /api/v1, work items, an events frame), fingerprint, check
#       4. L1 rollback (flags off, fork images): compare, check the app
#       5. L2 rollback (stock images): compare, check the app and the stock page endpoints,
#          check that the stock migrator and `migrate --check` are clean, create data as stock
#       6. go forward to the fork again: compare, check
#      Every comparison is against the previous fingerprint: a row that vanished, a changed
#      field of an untouched row or a table that lost rows is a FAIL with the exact detail.
#      Exit 0 only when every check passed. Without --keep the stack is removed at the end.
#   upgrade-rollback.sh compare OLD.json NEW.json [ROW_KEY...]
#                                 compare two fingerprints (offline); ROW_KEY (for example
#                                 page:<id>) names rows that are expected to change
#   upgrade-rollback.sh down      remove the stack and its volumes
#   upgrade-rollback.sh help
#
# Settings (environment): the ones of local-stack.sh (LOCAL_STACK_PROJECT, LOCAL_STACK_PORT,
# LOCAL_STACK_TLS_PORT, LOCAL_STACK_MINIO_IMAGE, LOCAL_STACK_DIR, COMPOSE_CMD) and
#   FORK_N                   fork image build number, default 2 (tag v1.4.2-live.2)
#   UPGRADE_ROLLBACK_REPORT  report file, default $LOCAL_STACK_DIR/upgrade-rollback.report
# Needs the stock images makeplane/plane-*:v1.4.2 and the fork images
# localhost/plane-fork-{web,live,api}:v1.4.2-live.$FORK_N loaded in the engine
# (fork/build/verify-load.sh loads a built archive). The compose files are never pulled from.
# Fingerprints, state and report are written to the settings directory (mode 600); they hold no
# secret values: the fingerprint only holds a hash of each API key. Secrets are never printed.
# shellcheck disable=SC2015 # "cond && ok || bad": ok never fails
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FORK_N=${FORK_N:-2}
export FORK_N
# shellcheck source=local-stack.sh
. "$HERE/local-stack.sh"
REPORT_FILE=${UPGRADE_ROLLBACK_REPORT:-$DIR/upgrade-rollback.report}
FP_DIR=$DIR/upgrade-fp

usage() { sed -n "3,32p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ session requests

# sreq METHOD URL SESSION [JSON_BODY] -> CODE, body in $BODY (browser-style call of the app API)
sreq() {
  local method=$1 url=$2 sess=$3 data=${4:-}
  local -a args=(-sS -m 30 -o "$BODY" -w '%{http_code}' -X "$method")
  printf 'Cookie: session-id=%s\n' "$sess" >"$TMP/shdr"
  args+=(-H "@$TMP/shdr")
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
  : >"$BODY"
  CODE=$(curl "${args[@]}" "$url" 2>/dev/null) || CODE=000
  [ -n "$CODE" ] || CODE=000
}

# jq_py EXPR: evaluate a python expression on the last body as `d` (json), print the result
jq_py() { python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=eval(sys.argv[2])
except Exception:
    v=""
print(v if v is not None else "")' "$BODY" "$1"; }

# ------------------------------------------------------------------ fingerprint

FP_SCRIPT=$(
  cat <<'PY'
import hashlib, json
from django.apps import apps


def h(v):
    if v is None:
        return "null"
    if isinstance(v, (bytes, bytearray, memoryview)):
        v = bytes(v)
        return "b:%d:%s" % (len(v), hashlib.sha256(v).hexdigest()[:16])
    return hashlib.sha256(str(v).encode("utf-8")).hexdigest()[:16]


counts = {}
for m in apps.get_models():
    try:
        counts[m._meta.db_table] = m._base_manager.count()
    except Exception as exc:
        counts[m._meta.db_table] = "error:%s" % type(exc).__name__

KINDS = [
    ("workspace", "Workspace", "name", ["name", "slug"]),
    ("user", "User", "email", ["email", "is_active"]),
    ("project", "Project", "name", ["name", "identifier", "cycle_view", "module_view", "page_view"]),
    ("state", "State", "name", ["name", "group", "project_id"]),
    ("issue", "Issue", "name", ["name", "description_html", "priority", "state_id", "sequence_id", "project_id", "parent_id"]),
    ("comment", "IssueComment", "comment_stripped", ["comment_html", "issue_id", "actor_id"]),
    ("label", "Label", "name", ["name", "color", "project_id"]),
    ("issuelabel", "IssueLabel", "issue_id", ["issue_id", "label_id"]),
    ("cycle", "Cycle", "name", ["name", "project_id"]),
    ("cycleissue", "CycleIssue", "issue_id", ["cycle_id", "issue_id"]),
    ("module", "Module", "name", ["name", "status", "project_id"]),
    ("moduleissue", "ModuleIssue", "issue_id", ["module_id", "issue_id"]),
    ("page", "Page", "name", ["name", "description_html", "description_stripped", "description_binary", "access", "owned_by_id", "is_locked", "archived_at", "parent_id"]),
    ("projectpage", "ProjectPage", "page_id", ["page_id", "project_id"]),
    ("apitoken", "APIToken", "label", ["label", "token", "user_id", "is_active"]),
]
rows = {}
from plane.db import models as dbm

for kind, model, namef, fields in KINDS:
    m = getattr(dbm, model, None)
    if m is None and model == "APIToken":
        from plane.db.models.api import APIToken as m  # noqa: F811
    if m is None:
        rows["missing-model:%s" % model] = {"_name": model}
        continue
    for o in m._base_manager.all():
        name = getattr(o, namef, "")
        rows["%s:%s" % (kind, o.pk)] = dict(
            [("_name", str(name)[:60])] + [(f, h(getattr(o, f, "<absent>"))) for f in fields]
        )

dups = 0
from django.db.models import Count

for r in dbm.Issue._base_manager.values("project_id", "sequence_id").annotate(n=Count("id")).filter(n__gt=1):
    dups += 1
print("FP " + json.dumps({"counts": counts, "rows": rows, "dup_sequence_ids": dups}, sort_keys=True))
PY
)

DIFF_SCRIPT=$(
  cat <<'PY'
import json, sys

old = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
allow = set(sys.argv[3:])
fails = []
# tables that are written by background tasks or sessions and may shrink legitimately: none known;
# a shrinking table is always reported
for t, n in sorted(old["counts"].items()):
    m = new["counts"].get(t)
    if isinstance(n, int) and isinstance(m, int) and m < n:
        fails.append("LOSS table %s: %d -> %d rows" % (t, n, m))
    elif m is None:
        fails.append("LOSS table %s is gone" % t)
for k, row in sorted(old["rows"].items()):
    r = new["rows"].get(k)
    if r is None:
        fails.append("LOSS %s '%s' is missing" % (k, row.get("_name", "")))
        continue
    if k in allow:
        continue
    for f, v in sorted(row.items()):
        if f != "_name" and r.get(f) != v:
            fails.append("CORRUPT %s '%s' field %s: %s -> %s" % (k, row.get("_name", ""), f, v, r.get(f)))
for k in sorted(allow):
    if k not in old["rows"]:
        fails.append("TEST ERROR allowed row %s is not in the old fingerprint" % k)
    elif k in new["rows"] and new["rows"][k] == old["rows"][k]:
        fails.append("TEST ERROR row %s was expected to change and did not" % k)
if new.get("dup_sequence_ids"):
    fails.append("CORRUPT %d duplicate (project, sequence_id) pairs" % new["dup_sequence_ids"])
added = sum(1 for k in new["rows"] if k not in old["rows"])
print("SUMMARY tables=%d rows_old=%d rows_new=%d added=%d" % (len(old["counts"]), len(old["rows"]), len(new["rows"]), added))
for line in fails[:40]:
    print(line)
if len(fails) > 40:
    print("... %d more" % (len(fails) - 40))
sys.exit(1 if fails else 0)
PY
)

# take_fp NAME -> $FP_DIR/NAME.json
take_fp() {
  local out
  mkdir -p "$FP_DIR"
  out=$(dc exec -T api python manage.py shell -c "$FP_SCRIPT" 2>"$TMP/fp.err" | tr -d '\r' | grep '^FP ' | tail -n 1)
  if [ -z "$out" ]; then
    bad "fingerprint $1" "no output: $(tail -n 1 "$TMP/fp.err" | cut -c1-120)"
    return 1
  fi
  printf '%s\n' "${out#FP }" >"$FP_DIR/$1.json"
  local n r
  n=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d["counts"]))' "$FP_DIR/$1.json")
  r=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d["rows"]))' "$FP_DIR/$1.json")
  report "   fingerprint $1: $n tables counted, $r rows hashed"
}

# compare_fp LABEL OLD NEW [allowed-changed-row-keys...]
compare_fp() {
  local label=$1 old=$2 new=$3 line summary="" rc=0
  shift 3
  [ -f "$FP_DIR/$old.json" ] && [ -f "$FP_DIR/$new.json" ] || { bad "$label" "fingerprint missing"; return 0; }
  python3 -c "$DIFF_SCRIPT" "$FP_DIR/$old.json" "$FP_DIR/$new.json" "$@" >"$TMP/diff.out" 2>&1 || rc=$?
  summary=$(grep '^SUMMARY ' "$TMP/diff.out")
  if [ "$rc" -eq 0 ]; then
    ok "$label ($summary)"
  else
    bad "$label" "${summary:-no summary}"
    while IFS= read -r line; do
      [[ $line == SUMMARY* ]] || report "     $line"
    done <"$TMP/diff.out"
  fi
}

# ------------------------------------------------------------------ state of the test data

URL=""
API=""
WSAPI=""
PID_A=""
PID_B=""
MK=""
AK=""
MS=""
AS=""
UK=""
ISSUES=()    # id|name of every work item the script created
PAGES=()     # id|project|marker of every page the script created
FORK_PAGE_IDS=()
PATCHED_PAGE=""     # stock page with a stored binary, PATCHed in the fork (rebase path)
PATCHED_NOBIN="" # stock page without a binary, PATCHed in the fork (direct path)
BIN_KEEP=""      # stock page with a binary the fork never touches
BIN_KEEP_SHA=""
BIN_PATCHED_SHA=""
LABEL_IDS=()
CYCLE_ID=""
MODULE_ID=""
FORK_ISSUE=""

init_vars() {
  URL=http://localhost:$(envval LISTEN_HTTP_PORT)
  API=$URL/api/v1/workspaces/$WORKSPACE_SLUG
  WSAPI=$URL/api/workspaces/$WORKSPACE_SLUG
  PID_A=$(stateval PROJECT_ID)
  MK=$(stateval MEMBER_KEY)
  AK=$(stateval ADMIN_KEY)
  MS=$(stateval MEMBER_SESSION)
  AS=$(stateval ADMIN_SESSION)
}

LAST_ID=""
# mk_issue PROJECT NAME [EXTRA_JSON_FIELDS] -> LAST_ID, recorded in ISSUES (no subshell: arrays)
mk_issue() {
  local pid=$1 name=$2 extra=${3:-}
  LAST_ID=""
  req POST "$API/projects/$pid/issues/" "$AK" "{\"name\":\"$name\",\"description_html\":\"<p>body of $name</p>\"$extra}"
  [ "$CODE" = 201 ] || return 1
  LAST_ID=$(jfield id)
  [ -n "$LAST_ID" ] || return 1
  ISSUES+=("$LAST_ID|$name")
}

# rename_record ID NEWNAME: keep the expected name of a work item that was renamed on purpose
rename_record() {
  local i
  for i in "${!ISSUES[@]}"; do
    [ "${ISSUES[$i]%%|*}" = "$1" ] && ISSUES[i]="$1|$2"
  done
}

# mk_page PROJECT SESSION NAME HTML MARKER -> LAST_ID (stock path: the app API)
mk_page() {
  local pid=$1 sess=$2 name=$3 html=$4 marker=$5
  LAST_ID=""
  sreq POST "$WSAPI/projects/$pid/pages/" "$sess" "{\"name\":\"$name\",\"description_html\":\"$html\"}"
  [ "$CODE" = 201 ] || return 1
  LAST_ID=$(jq_py 'd["id"]')
  [ -n "$LAST_ID" ] || return 1
  PAGES+=("$LAST_ID|$pid|$marker")
}

# page_bin_sha PAGE -> "<bytes>:<sha256 prefix>" of the description endpoint, empty when 0 bytes
page_bin_sha() {
  curl -sS -m 30 -o "$TMP/desc.bin" -H "Cookie: session-id=$AS" "$WSAPI/projects/$PID_A/pages/$1/description/" 2>/dev/null
  local n
  n=$(wc -c <"$TMP/desc.bin" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ] || return 0
  printf '%s:%s' "$n" "$(sha256sum "$TMP/desc.bin" | cut -c1-16)"
}

# seed_binary PAGE HTML: build the stored document through the live converter and write it with
# the stock description endpoint (the call the stock editor makes)
seed_binary() {
  local page=$1 html b64
  html=$(python3 -c 'import sys;sys.stdout.write(sys.argv[1].encode("ascii").decode("unicode_escape"))' "$2")
  b64=$(HTML="$html" dc exec -T -e HTML api python -c '
import os, requests
r = requests.post("http://live:3000/live/convert-document", json={"description_html": os.environ["HTML"], "variant": "document"},
                  headers={"live-server-secret-key": os.environ.get("LIVE_SERVER_SECRET_KEY", "")}, timeout=30)
print("BIN " + (r.json().get("description_binary") or "") if r.status_code == 200 else "ERR %s" % r.status_code)
' 2>/dev/null | tr -d '\r' | grep '^BIN ' | tail -n 1)
  b64=${b64#BIN }
  CODE=000
  [ -n "$b64" ] || return 1
  sreq PATCH "$WSAPI/projects/$PID_A/pages/$page/description/" "$MS" "{\"description_binary\":\"$b64\",\"description_html\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$html")}"
  [ "$CODE" = 200 ]
}

seed_stock() {
  report "-- seed data on the stock stack"
  local i id n
  # project A has cycles, modules and pages switched on; project B is a second project
  req PATCH "$API/projects/$PID_A/" "$AK" '{"cycle_view":true,"module_view":true,"page_view":true}'
  expect_code "seed: project A features on" '^200$'
  req POST "$API/projects/" "$AK" '{"name":"LU Upgrade B","identifier":"LUB"}'
  if [ "$CODE" = 201 ]; then
    PID_B=$(jfield id)
    ok "seed: second project created"
  else
    bad "seed: second project created" "http $CODE"
    return 1
  fi
  req PATCH "$API/projects/$PID_B/" "$AK" '{"page_view":true}'
  expect_code "seed: project B pages on" '^200$'

  for n in bug feature chore; do
    req POST "$API/projects/$PID_A/labels/" "$AK" "{\"name\":\"upg-$n\",\"color\":\"#336699\"}"
    id=$(jfield id)
    [ "$CODE" = 201 ] && [ -n "$id" ] && LABEL_IDS+=("$id") || bad "seed: label upg-$n" "http $CODE"
  done
  [ "${#LABEL_IDS[@]}" -eq 3 ] && ok "seed: 3 labels" || return 1

  req POST "$API/projects/$PID_A/cycles/" "$AK" "{\"name\":\"upg-cycle\",\"project_id\":\"$PID_A\",\"start_date\":\"2099-01-05\",\"end_date\":\"2099-01-19\"}"
  CYCLE_ID=$(jfield id)
  [ "$CODE" = 201 ] && ok "seed: cycle" || bad "seed: cycle" "http $CODE $(head -c 120 "$BODY")"
  req POST "$API/projects/$PID_A/modules/" "$AK" '{"name":"upg-module"}'
  MODULE_ID=$(jfield id)
  [ "$CODE" = 201 ] && ok "seed: module" || bad "seed: module" "http $CODE $(head -c 120 "$BODY")"

  local made=0 c
  for i in 1 2 3 4 5; do
    mk_issue "$PID_A" "upg issue $i" ",\"labels\":[\"${LABEL_IDS[$((i % 3))]}\"]" && made=$((made + 1)) || continue
    id=$LAST_ID
    if [ "$i" -le 3 ]; then
      for c in 1 2; do
        req POST "$API/projects/$PID_A/issues/$id/comments/" "$AK" "{\"comment_html\":\"<p>upg comment $c on issue $i caf\\u00e9</p>\"}"
        [ "$CODE" = 201 ] || bad "seed: comment $c on issue $i" "http $CODE"
      done
    fi
    if [ "$i" -le 2 ] && [ -n "$CYCLE_ID" ]; then
      req POST "$API/projects/$PID_A/cycles/$CYCLE_ID/cycle-issues/" "$AK" "{\"issues\":[\"$id\"]}"
      [[ $CODE =~ ^20[01]$ ]] || bad "seed: issue $i into the cycle" "http $CODE"
    fi
    if [ "$i" -ge 4 ] && [ -n "$MODULE_ID" ]; then
      req POST "$API/projects/$PID_A/modules/$MODULE_ID/module-issues/" "$AK" "{\"issues\":[\"$id\"]}"
      [[ $CODE =~ ^20[01]$ ]] || bad "seed: issue $i into the module" "http $CODE"
    fi
  done
  mk_issue "$PID_B" "upg issue B1" && made=$((made + 1))
  [ "$made" -eq 6 ] && ok "seed: 6 work items with comments, labels, cycle and module links" || bad "seed: work items" "made $made of 6"

  # pages through the app API, as the stock web UI creates them
  local p1 p2 p3 pb
  p1="" p2="" p3="" pb=""
  mk_page "$PID_A" "$MS" "upg page plain" '<p>upg-stock-page-1 plain text</p>' upg-stock-page-1 && p1=$LAST_ID
  mk_page "$PID_A" "$MS" "upg page rich" '<h2>Heading caf\u00e9 \u65e5\u672c\u8a9e</h2><ul><li>one</li><li>two</li></ul><p>upg-stock-page-2</p>' upg-stock-page-2 && p2=$LAST_ID
  mk_page "$PID_A" "$MS" "upg page to patch in fork" '<p>upg-stock-page-3 before the fork</p>' upg-stock-page-3 && p3=$LAST_ID
  mk_page "$PID_B" "$AS" "upg page project B" '<p>upg-stock-page-4 in project B</p>' upg-stock-page-4 && pb=$LAST_ID
  if [ -n "$p1" ] && [ -n "$p2" ] && [ -n "$p3" ] && [ -n "$pb" ]; then
    ok "seed: 4 pages with content"
    PATCHED_PAGE=$p3
    PATCHED_NOBIN=$p1
    BIN_KEEP=$p2
    # two pages get a stored document, as the stock editor writes it (live converts the html)
    seed_binary "$p2" '<h2>Heading caf\u00e9 \u65e5\u672c\u8a9e</h2><ul><li>one</li><li>two</li></ul><p>upg-stock-page-2</p>' && ok "seed: stored document on the rich page" || bad "seed: stored document on the rich page" "http $CODE"
    seed_binary "$p3" '<p>upg-stock-page-3 before the fork</p>' && ok "seed: stored document on the page the fork will PATCH" || bad "seed: stored document on the page the fork will PATCH" "http $CODE"
    BIN_KEEP_SHA=$(page_bin_sha "$p2")
    [ -n "$BIN_KEEP_SHA" ] && ok "seed: stored document of the rich page has ${BIN_KEEP_SHA%%:*} bytes" || bad "seed: stored document of the rich page" "empty"
  else
    bad "seed: 4 pages with content" "page create failed (last http $CODE)"
  fi

  # an API key created the way the web UI does it; its value stays in the state file only
  sreq POST "$URL/api/users/api-tokens/" "$MS" '{"label":"upg extra key","description":"upgrade test"}'
  UK=$(jq_py 'd["token"]')
  if [ "$CODE" = 201 ] && [ -n "$UK" ]; then
    state_set UPGRADE_KEY "$UK"
    ok "seed: extra API key created (value not printed)"
  else
    bad "seed: extra API key" "http $CODE"
  fi
  sleep 5 # let the worker finish the page and activity tasks
}

# ------------------------------------------------------------------ per-phase checks

# check_migrations LABEL [full]: nothing unapplied, the migrator ends clean
check_migrations() {
  local label=$1 mode=${2:-}
  if dc exec -T api python manage.py migrate --check >"$TMP/mig.out" 2>&1; then
    ok "$label: migrate --check (no unapplied migration)"
  else
    bad "$label: migrate --check" "$(tail -n 1 "$TMP/mig.out" | cut -c1-140)"
  fi
  if [ "$mode" = full ]; then
    if dc run --rm --no-deps -T migrator >"$TMP/migrator.out" 2>&1 && ! grep -qiE 'traceback|error' "$TMP/migrator.out"; then
      ok "$label: migrator run exits 0 without errors"
    else
      bad "$label: migrator run" "$(grep -iE 'traceback|error' "$TMP/migrator.out" | tail -n 1 | cut -c1-140)"
    fi
  fi
  if dc logs api worker 2>/dev/null | grep -qE 'ProgrammingError|UndefinedColumn|UndefinedTable|relation .* does not exist|InconsistentMigrationHistory'; then
    bad "$label: api and worker logs show no schema errors" "schema error found in the logs"
  else
    ok "$label: api and worker logs show no schema errors"
  fi
}

# check_data LABEL: the script's own rows read back through the public API and the app API
check_data() {
  local label=$1 row id name bad_n=0 pid marker html
  for row in "${ISSUES[@]}"; do
    id=${row%%|*}
    name=${row#*|}
    pid=$PID_A
    [[ $name == *B1 ]] && pid=$PID_B
    req GET "$API/projects/$pid/issues/$id/" "$AK"
    if [ "$CODE" != 200 ] || [ "$(jfield name)" != "$name" ]; then
      bad_n=$((bad_n + 1))
      report "     work item '$name': http $CODE name='$(jfield name)'"
    fi
  done
  [ "$bad_n" -eq 0 ] && ok "$label: ${#ISSUES[@]} work items read back by id with the right name" || bad "$label: work items read back" "$bad_n wrong"

  req GET "$API/projects/$PID_A/issues/?per_page=100" "$AK"
  local total
  total=$(jq_py 'd.get("total_results", len(d.get("results", [])))')
  [ "$CODE" = 200 ] && [ "$total" -ge 5 ] 2>/dev/null && ok "$label: work item list (project A) answers, $total items" || bad "$label: work item list (project A)" "http $CODE total=$total"

  local first
  first=$(printf '%s' "${ISSUES[0]}" | cut -d'|' -f1)
  req GET "$API/projects/$PID_A/issues/$first/comments/" "$AK"
  [ "$CODE" = 200 ] && [ "$(jq_py 'len(d.get("results", d) if isinstance(d, dict) else d)')" = 2 ] && ok "$label: comments of the first work item (2)" || bad "$label: comments of the first work item" "http $CODE count=$(jq_py 'len(d.get("results", d) if isinstance(d, dict) else d)')"

  req GET "$API/projects/$PID_A/labels/" "$AK"
  [ "$CODE" = 200 ] && grep -q 'upg-feature' "$BODY" && ok "$label: labels listed" || bad "$label: labels listed" "http $CODE"
  req GET "$API/projects/$PID_A/cycles/" "$AK"
  [ "$CODE" = 200 ] && grep -q 'upg-cycle' "$BODY" && ok "$label: cycle listed" || bad "$label: cycle listed" "http $CODE"
  req GET "$API/projects/$PID_A/modules/" "$AK"
  [ "$CODE" = 200 ] && grep -q 'upg-module' "$BODY" && ok "$label: module listed" || bad "$label: module listed" "http $CODE"

  # pages through the app API (the endpoints the stock UI uses), the marker must be in the html
  bad_n=0
  for row in "${PAGES[@]}"; do
    id=${row%%|*}
    pid=$(printf '%s' "$row" | cut -d'|' -f2)
    marker=${row##*|}
    sreq GET "$WSAPI/projects/$pid/pages/$id/" "$AS"
    html=$(jq_py 'd.get("description_html","")')
    if [ "$CODE" != 200 ] || [[ $html != *"$marker"* ]]; then
      bad_n=$((bad_n + 1))
      report "     page $marker (app API detail): http $CODE"
    fi
    sreq GET "$WSAPI/projects/$pid/pages/$id/description/" "$AS"
    [ "$CODE" = 200 ] || { bad_n=$((bad_n + 1)); report "     page $marker (app API description): http $CODE"; }
  done
  [ "$bad_n" -eq 0 ] && ok "$label: ${#PAGES[@]} pages open through the stock app API (detail + description)" || bad "$label: pages through the app API" "$bad_n wrong"

  # the extra API key still authenticates
  if [ -n "$UK" ]; then
    req GET "$API/projects/$PID_A/labels/" "$UK"
    expect_code "$label: extra API key still authenticates" '^200$'
  fi
  # the session of the member survived
  sreq GET "$URL/api/users/me/" "$MS"
  expect_code "$label: member session still valid" '^200$'
}

# check_app LABEL KIND (fork|l1|stock): the app works: reads, a write, the front end, pages API per KIND
check_app() {
  local label=$1 kind=$2 id
  req GET "$URL/api/instances/" ""
  expect_code "$label: instance endpoint" '^200$'
  req GET "$URL/" ""
  expect_code "$label: web front end" '^200$'
  req GET "$URL/live/health" ""
  expect_code "$label: live health" '^200$'
  id=""
  if mk_issue "$PID_A" "upg issue written in $label"; then id=$LAST_ID; ok "$label: new work item created"; else bad "$label: new work item created" "http $CODE"; fi
  if [ -n "$id" ]; then
    req POST "$API/projects/$PID_A/issues/$id/comments/" "$AK" '{"comment_html":"<p>written after the switch</p>"}'
    expect_code "$label: comment on the new work item" '^201$'
    req PATCH "$API/projects/$PID_A/issues/$id/" "$AK" "{\"name\":\"upg issue written in $label (edited)\"}"
    expect_code "$label: PATCH of the new work item" '^200$'
    rename_record "$id" "upg issue written in $label (edited)"
  fi
  req GET "$API/projects/$PID_A/pages/" "$MK"
  if [ "$kind" = fork ]; then
    expect_code "$label: /api/v1 pages API answers 200" '^200$'
    local missing=0 row
    for row in "${PAGES[@]}"; do
      [ "$(printf '%s' "$row" | cut -d'|' -f2)" = "$PID_A" ] || continue
      grep -q "${row%%|*}" "$BODY" || missing=$((missing + 1))
    done
    [ "$missing" -eq 0 ] && ok "$label: /api/v1 pages list holds all project A pages" || bad "$label: /api/v1 pages list holds all pages" "$missing missing"
  else
    expect_code "$label: /api/v1 pages API answers 404" '^404$'
  fi
}

# check_patched_page LABEL: pages the fork changed or kept, read the way the stock UI reads them
check_patched_page() {
  local label=$1 sha
  sreq GET "$WSAPI/projects/$PID_A/pages/$PATCHED_PAGE/" "$AS"
  if [ "$CODE" = 200 ] && jq_py 'd.get("description_html","")' | grep -q 'upg-patched-in-fork'; then ok "$label: page with a stored document, PATCHed in the fork, shows the new text"; else bad "$label: page with a stored document, PATCHed in the fork, shows the new text" "http $CODE"; fi
  sreq GET "$WSAPI/projects/$PID_A/pages/$PATCHED_NOBIN/" "$AS"
  if [ "$CODE" = 200 ] && jq_py 'd.get("description_html","")' | grep -q 'upg-patched-nobinary-in-fork'; then ok "$label: page without a stored document, PATCHed in the fork, shows the new text"; else bad "$label: page without a stored document, PATCHed in the fork, shows the new text" "http $CODE"; fi
  sha=$(page_bin_sha "$BIN_KEEP")
  [ -n "$sha" ] && [ "$sha" = "$BIN_KEEP_SHA" ] && ok "$label: stored document of the untouched stock page is byte-identical ($sha)" || bad "$label: stored document of the untouched stock page is byte-identical" "want $BIN_KEEP_SHA got ${sha:-empty}"
  sha=$(page_bin_sha "$PATCHED_PAGE")
  if [ -z "$BIN_PATCHED_SHA" ]; then
    BIN_PATCHED_SHA=$sha
    [ -n "$sha" ] && ok "$label: the fork wrote a new stored document ($sha), readable by the description endpoint" || bad "$label: the fork wrote a stored document" "empty"
  else
    [ "$sha" = "$BIN_PATCHED_SHA" ] && ok "$label: stored document written by the fork is byte-identical ($sha)" || bad "$label: stored document written by the fork is byte-identical" "want $BIN_PATCHED_SHA got ${sha:-empty}"
  fi
}

events_check() { # events_check LABEL: a PATCH with the API key delivers a frame (fork flags on)
  local label=$1 ws origin out lat
  ws=ws://localhost:$(envval LISTEN_HTTP_PORT)/live/events
  origin=$(envval WEB_URL)
  out=$(WS_COOKIE="session-id=$MS" WS_API_KEY="$AK" probe --mode latency --url "$ws" --origin "$origin" \
    --slug "$WORKSPACE_SLUG" --project "$PID_A" --issue "$FORK_ISSUE" --patch-url "$API/projects/$PID_A/issues/$FORK_ISSUE/" \
    --patch-body '{"name":"upg issue created in fork (edited)"}' --timeout 12)
  rename_record "$FORK_ISSUE" "upg issue created in fork (edited)"
  lat=$(pj "$out" latency)
  if [ "$(pj "$out" patch_status)" = 200 ] && [ -n "$lat" ]; then ok "$label: events frame delivered for an issue PATCH (${lat}s)"; else bad "$label: events frame delivered" "patch=$(pj "$out" patch_status) latency=${lat:-none}"; fi
}

# ------------------------------------------------------------------ the run

preflight() {
  local img missing=0
  for img in plane-backend plane-frontend plane-live plane-admin plane-space plane-proxy; do
    image_exists "makeplane/$img:v1.4.2" || { log "missing stock image makeplane/$img:v1.4.2"; missing=1; }
  done
  for img in web live api; do
    image_exists "localhost/plane-fork-$img:v1.4.2-live.$FORK_N" || { log "missing image localhost/plane-fork-$img:v1.4.2-live.$FORK_N (load it with fork/build/verify-load.sh)"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "images missing, load them first"
}

cmd_run() {
  local keep=0 arg
  for arg in "$@"; do
    case "$arg" in
      --keep) keep=1 ;;
      *) die "run: unknown option $arg (use --keep)" ;;
    esac
  done
  detect_compose
  preflight
  : >"$REPORT_FILE"
  rm -rf "$FP_DIR"
  report "UPGRADE/ROLLBACK REPORT stock v1.4.2 -> fork tag v1.4.2-live.$FORK_N, compose provider: $COMPOSE"

  report "== 1. stock stack"
  cmd_up --stock >"$TMP/up.out" 2>&1 || { tail -n 8 "$TMP/up.out"; die "stock stack did not start"; }
  init_vars
  MODE=stock
  count_images
  image_check "stock: no service runs a fork image" 0
  seed_stock
  [ "$FAIL_N" -eq 0 ] || { report "seeding failed, stopping"; finish "$keep"; return; }

  report "== 2. fingerprint on stock, check"
  take_fp 0-stock
  check_data "stock"
  check_migrations "stock"

  report "== 3. upgrade to the fork images (flags on)"
  gen_l1
  if switch fork "${FORK_SVCS[@]}"; then
    settle "upgrade" "$URL" "$API/projects/$PID_A" "$MK" 180
    MODE=fork
    count_images
    image_check "upgrade: 5 services run fork images" 5
  else
    bad "upgrade" "compose up failed"
    finish "$keep"
    return
  fi
  check_migrations "fork" full
  if dc exec -T api python manage.py makemigrations --check --dry-run >"$TMP/mm.out" 2>&1; then
    ok "fork: makemigrations --check (the fork images carry no model change)"
  else
    bad "fork: makemigrations --check" "$(tail -n 2 "$TMP/mm.out" | tr '\n' ' ' | cut -c1-160)"
  fi
  local fp id
  FORK_ISSUE=""
  if mk_issue "$PID_A" "upg issue created in fork"; then FORK_ISSUE=$LAST_ID; ok "fork: work item created"; else bad "fork: work item created" "http $CODE"; fi
  # pages through /api/v1 (fork only)
  for fp in 1 2; do
    req POST "$API/projects/$PID_A/pages/" "$MK" "{\"name\":\"upg fork page $fp\",\"description_html\":\"<p>upg-fork-page-$fp caf\\u00e9</p>\"}"
    id=$(jfield id)
    if [ "$CODE" = 201 ] && [ -n "$id" ]; then
      ok "fork: page $fp created through /api/v1"
      PAGES+=("$id|$PID_A|upg-fork-page-$fp")
      FORK_PAGE_IDS+=("$id")
    else
      bad "fork: page $fp created through /api/v1" "http $CODE"
    fi
  done
  local before_sha
  before_sha=$(page_bin_sha "$PATCHED_PAGE")
  [ -n "$before_sha" ] && ok "fork: the page to PATCH has a stored document from stock ($before_sha)" || bad "fork: the page to PATCH has a stored document from stock" "empty"
  req PATCH "$API/projects/$PID_A/pages/$PATCHED_PAGE/" "$MK" '{"description_html":"<p>upg-patched-in-fork</p>"}'
  expect_code "fork: PATCH through /api/v1 of a stock page with a stored document (rebase through live)" '^200$'
  [ "$(page_bin_sha "$PATCHED_PAGE")" != "$before_sha" ] && ok "fork: that PATCH changed the stored document" || bad "fork: that PATCH changed the stored document" "same bytes"
  req PATCH "$API/projects/$PID_A/pages/$PATCHED_NOBIN/" "$MK" '{"description_html":"<p>upg-patched-nobinary-in-fork</p>"}'
  expect_code "fork: PATCH through /api/v1 of a stock page without a stored document" '^200$'
  # one stock-created page keeps its marker for the readers; the patched one now carries a new one
  local i
  for i in "${!PAGES[@]}"; do
    [ "${PAGES[$i]%%|*}" = "$PATCHED_PAGE" ] && PAGES[i]="$PATCHED_PAGE|$PID_A|upg-patched-in-fork"
    [ "${PAGES[$i]%%|*}" = "$PATCHED_NOBIN" ] && PAGES[i]="$PATCHED_NOBIN|$PID_A|upg-patched-nobinary-in-fork"
  done
  events_check "fork"
  check_app "fork" fork
  check_data "fork"
  check_patched_page "fork"
  sleep 5
  take_fp 1-fork
  compare_fp "upgrade: every stock row intact (only the two PATCHed pages may change)" 0-stock 1-fork "page:$PATCHED_PAGE" "page:$PATCHED_NOBIN"

  report "== 4. L1 rollback (flags off, fork images)"
  gen_l1
  if switch l1 "${L1_SVCS[@]}"; then
    settle "L1" "$URL" "$API/projects/$PID_A" "$MK" 120
    MODE=l1
    check_app "L1" l1
    check_data "L1"
    check_patched_page "L1"
    check_migrations "L1"
    sleep 3
    take_fp 2-l1
    compare_fp "L1: fork data and stock data intact" 1-fork 2-l1
  else
    bad "L1 apply" "compose up failed"
  fi

  report "== 5. L2 rollback (stock images)"
  if switch stock "${FORK_SVCS[@]}"; then
    settle "L2" "$URL" "$API/projects/$PID_A" "$MK" 180
    MODE=stock
    count_images
    image_check "L2: no service runs a fork image" 0
    check_migrations "L2" full
    check_app "L2" stock
    check_data "L2"
    check_patched_page "L2"
    sleep 3
    take_fp 3-l2
    local prev=2-l1
    [ -f "$FP_DIR/2-l1.json" ] || prev=1-fork
    compare_fp "L2: pre-upgrade, fork and L1 data intact under stock" "$prev" 3-l2
  else
    bad "L2 apply" "compose up failed"
  fi

  report "== 6. forward to the fork again"
  if switch fork "${FORK_SVCS[@]}"; then
    settle "forward" "$URL" "$API/projects/$PID_A" "$MK" 180
    MODE=fork
    count_images
    image_check "forward: 5 services run fork images" 5
    check_migrations "forward" full
    check_app "forward" fork
    check_data "forward"
    check_patched_page "forward"
    sleep 3
    take_fp 4-forward
    compare_fp "forward: everything including data written by stock is intact" 3-l2 4-forward
  else
    bad "forward" "compose up failed"
  fi
  finish "$keep"
}

finish() {
  report ""
  report "SUMMARY: $PASS_N passed, $FAIL_N failed"
  if [ "$1" -eq 0 ]; then
    MODE=fork
    cmd_down >/dev/null 2>&1 && report "stack removed (project $PROJECT)" || report "stack removal failed (project $PROJECT)"
  else
    report "stack kept (project $PROJECT); remove it with: $0 down"
  fi
  [ "$FAIL_N" -eq 0 ]
}

cmd_compare() {
  [ "$#" -ge 2 ] || die "usage: $0 compare OLD.json NEW.json [ROW_KEY...]"
  [ -f "$1" ] && [ -f "$2" ] || die "compare: fingerprint file not found"
  python3 -c "$DIFF_SCRIPT" "$@"
}

main_ur() {
  local sub=${1:-help}
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    run) cmd_run "$@" ;;
    compare) cmd_compare "$@" ;;
    down) cmd_down ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main_ur "$@"
