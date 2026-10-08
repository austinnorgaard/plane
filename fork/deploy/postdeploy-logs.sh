#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# postdeploy-logs.sh - objective post-deploy check of the api, worker,
# beat-worker and live logs (RUNBOOK section 7a).
#
# Runs on a workstation and reaches the Plane container the way the RUNBOOK
# does: ssh to the hypervisor, then `pct exec` into the container, where it
# runs `docker compose logs --since <window>` for api, worker, beat-worker and
# live. The raw logs are brought back to a private temporary file, counted
# locally, and deleted on exit. They are never printed. Only counts and a short
# list of distinct error lines are printed, after redaction (emails, IPv4 and
# IPv6 addresses, UUIDs, long hex and token strings, bearer and basic
# credentials, api-key and token headers, cookies, URL credentials).
#
# What is counted
#   http_5xx              access-log lines with a 5xx status
#   http_503              access-log lines with status 503 (also part of http_5xx)
#   page_patch_409        PATCH on a pages URL answered 409
#     unknown_409         lower bound of those where the live presence check failed
#                         (the api logs one warning per failed check); the rest is
#                         reported as loaded_409 (upper bound: the api also answers
#                         409 for a bad presence answer without logging)
#   page_patch_503        PATCH on a pages URL answered 503
#   opened_during_update  "page ... was opened in an editor during an api update" warnings
#   tracebacks            Python tracebacks
#   error_log_lines       other ERROR or CRITICAL log lines (api, worker, beat-worker)
#   live_errors           live lines that report an error, fatal, unhandled or uncaught problem
#   closes_<code>         live socket closes with code 4401, 4403, 4429 or 1013
#   rate_limit_overflows  lines about rate limits or overflows, plus 429 answers
#   live_auth_failures    last "authentication failures, running count" value from live
#   live_invalid_redis    last "dropped invalid Redis messages, running count" value
#
# Required environment (operator supplied, no defaults):
#   PVE_HOST        ssh target of the hypervisor
#   PLANE_CTID      container id on the hypervisor (numeric)
#   PLANE_APP_DIR   absolute path of the plane-app directory in the container
#
# Usage: postdeploy-logs.sh [options]
#   --window W            log window, a number and s, m or h (default 15m)
#   --top N               distinct error lines to print, 1 to 50 (default 10)
#   --timeout SECS        overall time limit of the ssh call, 5 to 900 (default 120)
#   --max-5xx N           default 5
#   --max-503 N           default 2
#   --max-tracebacks N    default 0
#   --max-live-errors N   default 0
#   --max-closes N        total of the four close codes, default 50
#   --max-ratelimit N     default 10
#   --max-opened-during N default 0
#   --max-409-unknown N   default 0
#   --dry-run             print the ssh command; connect nowhere
#   --redact-stdin        filter stdin to stdout through the redaction and exit
#                         (no environment needed; used by the tests)
#
# A count is over its threshold when it is greater than the maximum.
#
# Exit status: 0 clean, 1 over a threshold, 2 usage or validation error,
# 3 the remote call failed, timed out, or returned incomplete output. It fails
# closed: a log it could not read is never reported as clean.
set -u

die() { echo "error: $*" >&2; exit 2; }
usage() { echo "usage: postdeploy-logs.sh [--window W] [--top N] [--timeout S] [--max-...] [--dry-run]" >&2; exit 2; }

# redact: stdin to stdout. Order matters: whole-line header rules first, then
# key=value secrets, then shapes (email, jwt, uuid, hex, ipv6, ipv4, tokens).
# Needs GNU sed (the I flag). One rule per line.
redact() {
  sed -E \
    -e "s/(set-cookie|cookies?)[[:space:]]*[:=].*/\\1: [REDACTED]/Ig" \
    -e "s/((proxy-)?authorization)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[^\"',]*/\\1: [REDACTED]/Ig" \
    -e "s/(x-api-key|api[_-]?key|x-auth-token|auth[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|token|client[_-]?secret|secret|password|passwd|pwd|signature|session[_-]?id|session|csrf[_-]?token|x-csrftoken|live-server-secret-key|private[_-]?key|credentials?)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[^[:space:]\"'\&,;}]+/\\1=[REDACTED]/Ig" \
    -e "s/Bearer[[:space:]]+[A-Za-z0-9._~+\\/=-]+/Bearer [REDACTED]/Ig" \
    -e "s/Basic[[:space:]]+[A-Za-z0-9+\\/=]{8,}/Basic [REDACTED]/Ig" \
    -e "s#(://)[^/@[:space:]]+@#\\1[REDACTED]@#g" \
    -e "s/[A-Za-z0-9._%+'-]+(@|%40)[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+/[EMAIL]/g" \
    -e "s/eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*/[JWT]/g" \
    -e "s/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[UUID]/g" \
    -e "s/\\b[0-9a-fA-F]{24,}\\b/[HEX]/g" \
    -e "s/(^|[^0-9A-Za-z:.])(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})::(([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})?(:[0-9]{1,3}(\\.[0-9]{1,3}){3})?)|::[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6}(:[0-9]{1,3}(\\.[0-9]{1,3}){3})?)/\\1[IPV6]/g" \
    -e "s/[0-9]{1,3}(\\.[0-9]{1,3}){3}/[IPV4]/g" \
    -e "s/[A-Za-z0-9_-]{32,}/[TOKEN]/g" \
    -e "s/\\x1b\\[[0-9;]*[A-Za-z]//g" \
    -e "s/[[:cntrl:]]//g"
}

if [ "${1:-}" = --redact-stdin ]; then
  [ "$#" = 1 ] || usage
  redact
  exit 0
fi

isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 9 ]; }

DRY=0
WINDOW=15m
TOP=10
TIMEOUT=120
MAX_5XX=5 MAX_503=2 MAX_TB=0 MAX_LIVE=0 MAX_CLOSES=50 MAX_RL=10 MAX_OPENED=0 MAX_409U=0
while [ "$#" -gt 0 ]; do
  a=$1
  case "$a" in
    --dry-run) DRY=1; shift; continue ;;
    -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --window|--top|--timeout|--max-5xx|--max-503|--max-tracebacks|--max-live-errors|--max-closes|--max-ratelimit|--max-opened-during|--max-409-unknown) ;;
    *) usage ;;
  esac
  [ "$#" -ge 2 ] || usage
  v=$2
  shift 2
  case "$a" in
    --window)
      case "$v" in
        [1-9][smh]|[1-9][0-9][smh]|[1-9][0-9][0-9][smh]|[1-9][0-9][0-9][0-9][smh]) WINDOW=$v ;;
        *) die "--window must be a number and s, m or h (for example 15m)" ;;
      esac ;;
    --top) isnum "$v" && [ "$v" -ge 1 ] && [ "$v" -le 50 ] || die "--top must be 1 to 50"; TOP=$v ;;
    --timeout) isnum "$v" && [ "$v" -ge 5 ] && [ "$v" -le 900 ] || die "--timeout must be 5 to 900"; TIMEOUT=$v ;;
    *)
      isnum "$v" || die "$a needs a non-negative number"
      case "$a" in
        --max-5xx) MAX_5XX=$v ;;
        --max-503) MAX_503=$v ;;
        --max-tracebacks) MAX_TB=$v ;;
        --max-live-errors) MAX_LIVE=$v ;;
        --max-closes) MAX_CLOSES=$v ;;
        --max-ratelimit) MAX_RL=$v ;;
        --max-opened-during) MAX_OPENED=$v ;;
        --max-409-unknown) MAX_409U=$v ;;
      esac ;;
  esac
done

: "${PVE_HOST:=}" "${PLANE_CTID:=}" "${PLANE_APP_DIR:=}"
[ -n "$PVE_HOST" ] && [ -n "$PLANE_CTID" ] && [ -n "$PLANE_APP_DIR" ] || die "set PVE_HOST, PLANE_CTID and PLANE_APP_DIR"
case "$PVE_HOST" in -*|*[!A-Za-z0-9._@:-]*) die "PVE_HOST has unexpected characters" ;; esac
case "$PLANE_CTID" in *[!0-9]*) die "PLANE_CTID must be numeric" ;; esac
case "$PLANE_APP_DIR" in /*) ;; *) die "PLANE_APP_DIR must be an absolute path" ;; esac
case "$PLANE_APP_DIR" in *[!A-Za-z0-9._/-]*) die "PLANE_APP_DIR has unexpected characters" ;; esac

SERVICES="api worker beat-worker live"
MARK="@@PDL-$RANDOM$RANDOM$RANDOM@@"

# Remote script (POSIX sh, run in the container, cwd = PLANE_APP_DIR).
# Prints a marker line before each service and an END marker last; the marker
# carries a per-run random number so a log line cannot forge it.
read -r -d '' S_LOGS <<'EOF'
cd "$APP_DIR" || exit 3
rc=0
for s in api worker beat-worker live; do
  echo "$MARK $s"
  docker compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env logs --no-color --no-log-prefix --since "$WINDOW" "$s" 2>&1 || rc=3
done
echo "$MARK END"
exit $rc
EOF

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

# sq <text>: POSIX single-quote text for the remote shell.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

REMOTE="pct exec $PLANE_CTID -- env APP_DIR=$PLANE_APP_DIR WINDOW=$WINDOW MARK=$MARK sh -c $(sq "$S_LOGS")"

if [ "$DRY" = 1 ]; then
  echo "[dry-run] window $WINDOW, services: $SERVICES"
  echo "+ timeout $TIMEOUT ssh ${SSH_OPTS[*]} $PVE_HOST"
  echo "  remote command, sent as one argument:"
  printf '%s\n' "$REMOTE" | sed 's/^/    /'
  echo "RESULT: dry-run only, nothing was run"
  exit 0
fi

TMPD=$(mktemp -d) || { echo "error: cannot create a temporary directory" >&2; exit 3; }
trap 'rm -rf "$TMPD"' EXIT
RAW=$TMPD/raw
CAND=$TMPD/cand
: >"$CAND"

TO=()
command -v timeout >/dev/null 2>&1 && TO=(timeout "$TIMEOUT")
# shellcheck disable=SC2029  # expanding the command on the client side is intended
"${TO[@]}" ssh "${SSH_OPTS[@]}" "$PVE_HOST" "$REMOTE" </dev/null 2>/dev/null | tr -d '\r' | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' >"$RAW"
rc=${PIPESTATUS[0]}
if [ "$rc" != 0 ]; then
  if [ "$rc" = 124 ]; then
    echo "RESULT: remote call timed out after $TIMEOUT s; logs were not checked" >&2
  else
    echo "RESULT: remote call failed (rc=$rc); logs were not checked" >&2
  fi
  exit 3
fi
for s in $SERVICES END; do
  grep -qxF "$MARK $s" "$RAW" || { echo "RESULT: incomplete remote output (no section for $s); logs were not checked" >&2; exit 3; }
done

# One awk pass: counts as "key value" lines on stdout, candidate lines in $CAND.
COUNTS=$(awk -v mark="$MARK" -v cfile="$CAND" '
function cand(t) { print svc ": " t >> cfile }
function lastnum(s,   m) { match(s, /[0-9]+$/); return substr(s, RSTART) + 0 }
BEGIN { svc = ""; intb = 0 }
index($0, mark " ") == 1 {
  svc = substr($0, length(mark) + 2); intb = 0
  if (svc != "END") seen[svc] = 1
  next
}
svc == "" || svc == "END" { next }
{
  lines[svc]++
  line = $0
  low = tolower(line)
  isacc = 0
  if (match(line, /"[A-Z]+ [^" ]+ HTTP\/[0-9.]+" [0-9][0-9][0-9]( |$)/)) {
    seg = substr(line, RSTART, RLENGTH)
    n = split(seg, a, " ")
    method = substr(a[1], 2); path = a[2]; status = a[n]
    sub(/\?.*/, "", path)
    isacc = 1
    if (status ~ /^5/) { c5xx++; cand(method " " path " " status) }
    if (status == "503") c503++
    if (status == "429") rl++
    if (method == "PATCH" && path ~ /\/pages\//) {
      if (status == "409") p409++
      if (status == "503") p503++
    }
  }
  if (index(line, "Traceback (most recent call last)")) { tb++; intb = 1; next }
  if (intb) {
    if (line ~ /^[ \t]/ || line == "" || line ~ /^(During handling|The above exception)/) next
    cand("traceback: " line); intb = 0; next
  }
  if (index(line, "live presence check failed")) unk++
  if (index(line, "opened in an editor during an api update")) opened++
  if (!isacc && low ~ /rate.?limit|overflow/) rl++
  if (!isacc && svc != "live" && line ~ /(^|[ \[])(ERROR|CRITICAL)([] :\/]|$)/) { errlog++; cand(line) }
  if (svc == "live") {
    if (match(low, /(close|code)[^0-9]*(4401|4403|4429|1013)/)) {
      code = substr(low, RSTART + RLENGTH - 4, 4); cl[code]++
    }
    if (low ~ /error|fatal|unhandled|uncaught|exception/) { liveerr++; cand(line) }
    if (match(line, /authentication failures, running count [0-9]+/)) authf = lastnum(substr(line, RSTART, RLENGTH))
    if (match(line, /dropped invalid Redis messages, running count [0-9]+/)) invr = lastnum(substr(line, RSTART, RLENGTH))
  }
}
END {
  split("api worker beat-worker live", sv, " ")
  for (i = 1; i <= 4; i++) print "lines_" sv[i], lines[sv[i]] + 0
  print "http_5xx", c5xx + 0
  print "http_503", c503 + 0
  print "page_patch_409", p409 + 0
  print "unknown_409", (unk + 0 < p409 + 0 ? unk + 0 : p409 + 0)
  print "page_patch_503", p503 + 0
  print "opened_during_update", opened + 0
  print "tracebacks", tb + 0
  print "error_log_lines", errlog + 0
  print "live_errors", liveerr + 0
  print "closes_4401", cl["4401"] + 0
  print "closes_4403", cl["4403"] + 0
  print "closes_4429", cl["4429"] + 0
  print "closes_1013", cl["1013"] + 0
  print "rate_limit_overflows", rl + 0
  print "live_auth_failures", authf + 0
  print "live_invalid_redis", invr + 0
}' "$RAW") || { echo "RESULT: could not analyse the logs" >&2; exit 3; }

c_5xx=0 c_503=0 c_409=0 c_409u=0 c_p503=0 c_open=0 c_tb=0 c_errlog=0 c_live=0
c_4401=0 c_4403=0 c_4429=0 c_1013=0 c_rl=0 c_af=0 c_ir=0 l_api=0 l_worker=0 l_beat=0 l_live=0
while read -r k v; do
  isnum "$v" || { echo "RESULT: unexpected analysis output" >&2; exit 3; }
  case "$k" in
    lines_api) l_api=$v ;; lines_worker) l_worker=$v ;; lines_beat-worker) l_beat=$v ;; lines_live) l_live=$v ;;
    http_5xx) c_5xx=$v ;; http_503) c_503=$v ;;
    page_patch_409) c_409=$v ;; unknown_409) c_409u=$v ;; page_patch_503) c_p503=$v ;;
    opened_during_update) c_open=$v ;; tracebacks) c_tb=$v ;; error_log_lines) c_errlog=$v ;;
    live_errors) c_live=$v ;;
    closes_4401) c_4401=$v ;; closes_4403) c_4403=$v ;; closes_4429) c_4429=$v ;; closes_1013) c_1013=$v ;;
    rate_limit_overflows) c_rl=$v ;; live_auth_failures) c_af=$v ;; live_invalid_redis) c_ir=$v ;;
  esac
done <<<"$COUNTS"

total=$((l_api + l_worker + l_beat + l_live))
if [ "$total" = 0 ]; then
  echo "RESULT: the remote call returned no log lines at all; logs were not checked" >&2
  exit 3
fi
closes=$((c_4401 + c_4403 + c_4429 + c_1013))

echo "post-deploy log summary, window $WINDOW"
echo "log lines: api=$l_api worker=$l_worker beat-worker=$l_beat live=$l_live"
for pair in api:$l_api worker:$l_worker beat-worker:$l_beat live:$l_live; do
  [ "${pair##*:}" = 0 ] && echo "WARN: no log lines from ${pair%%:*} in the window"
done
echo "counts (maximum allowed in brackets):"
OVER=()
row() { # row <name> <count> <max>   (max "-" = informational)
  if [ "$3" = - ]; then
    printf '  %-22s %s\n' "$1" "$2"
  else
    local flag=
    [ "$2" -gt "$3" ] && { flag="  OVER"; OVER+=("$1"); }
    printf '  %-22s %s [%s]%s\n' "$1" "$2" "$3" "$flag"
  fi
}
row http_5xx "$c_5xx" "$MAX_5XX"
row http_503 "$c_503" "$MAX_503"
row page_patch_409 "$c_409" -
row "  loaded_409 (upper)" "$((c_409 - c_409u))" -
row unknown_409 "$c_409u" "$MAX_409U"
row page_patch_503 "$c_p503" -
row opened_during_update "$c_open" "$MAX_OPENED"
row tracebacks "$c_tb" "$MAX_TB"
row error_log_lines "$c_errlog" -
row live_errors "$c_live" "$MAX_LIVE"
row live_closes_total "$closes" "$MAX_CLOSES"
row "  close_4401 (auth)" "$c_4401" -
row "  close_4403 (origin)" "$c_4403" -
row "  close_4429 (rate)" "$c_4429" -
row "  close_1013 (retry)" "$c_1013" -
row rate_limit_overflows "$c_rl" "$MAX_RL"
row live_auth_failures "$c_af" -
row live_invalid_redis "$c_ir" -

echo "top distinct error lines (redacted):"
if [ -s "$CAND" ]; then
  sed -E -e 's/^([a-z-]+: )\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.,]+(Z| ?[+-][0-9]{2}:?[0-9]{2})?\]? ?/\1/' \
         -e 's/\[[0-9]+\]/[N]/g' "$CAND" \
    | redact | cut -c1-200 | sort | uniq -c | sort -k1,1nr -k2 | head -n "$TOP" | sed 's/^/  /'
else
  echo "  none"
fi

if [ "${#OVER[@]}" -gt 0 ]; then
  echo "RESULT: OVER THRESHOLD: ${OVER[*]}"
  exit 1
fi
echo "RESULT: clean"
exit 0
