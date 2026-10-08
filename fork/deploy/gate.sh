#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# gate.sh - one command that says GO or NO-GO before a production deploy.
#
# Usage: gate.sh [-e ENV_FILE] RELEASE_SHA
#
#   RELEASE_SHA   full 40-digit sha of the commit being deployed.
#   -e ENV_FILE   file with the deploy settings (a copy of plane.env), KEY=VALUE
#                 lines. Without it the settings are read from the environment.
#
# Each check prints PASS or FAIL. The last line is "RESULT: GO" (exit 0) or
# "RESULT: NO-GO" with the failing items (exit 1). Bad arguments exit 2.
# Nothing is changed anywhere. Secret values are never printed: only key NAMES.
#
# Inputs (environment; none has a default except where stated):
#   GATE_INSPECT_TIMEOUT  seconds allowed for inspect.sh (default 300)
#   QA_RECORD         file holding the QA verdict text; needs a line "QA: PASS @ <sha>"
#                     naming RELEASE_SHA (the full sha is preferred; 7 or more digits are accepted) and no "QA: FAIL @ <sha>" line for it
#   IMAGE_TAR         the image archive plane-fork-live.<N>.tar
#   (Known limitation: the IPv6 floor is /16, so ::/16 passes although it covers the
#    IPv4-mapped range; the IPv4 floor is /8.)
#   IMAGE_SHA256      sha256 from the build output; or BUILD_NOTES, the saved build output
#                     with its "Tar sha256: <hex>" line. The archive must also be bound to
#                     RELEASE_SHA: every image in it carries the label plane-fork-build=<sha>
#                     (read from the archive, nothing loaded), and a BUILD_NOTES file, if
#                     given, must have a "SHA verified: <sha>" line naming it
#   RUNBOOK_FILE      the runbook copy whose "Inspection results" table you filled
#                     (default: RUNBOOK.md next to this script)
#   STOCK_RELEASE     tag of the stock images now running (rollback L2)
#   PVE_HOST, PLANE_CTID, PLANE_APP_DIR
#                     inspect.sh is run on the hypervisor over ssh, as in RUNBOOK step 1.
#                     Without PVE_HOST it runs locally and needs `pct` on the PATH.
#   GATE_REPO         git checkout to check the sha in (default: the repository of this script)
#   OVERRIDE_FILE     compose override that carries the L1 flags (default: next to this script)
#   Settings read from ENV_FILE or the environment:
#     LIVE_EVENTS_TRUSTED_PROXIES, PAGES_REBASE_MAX_HTML_BYTES, PAGES_API_MAX_HTML_BYTES,
#     PAGES_REBASE_WORKER_MAX_MB, NODE_OPTIONS, LIVE_SERVER_SECRET_KEY
#
# Exit status: 0 GO, 1 NO-GO, 2 usage.
set -u

BRANCH=live-updates/v1.4.2
PLACEHOLDER=change-this-key-on-deployment
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

env_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n "2,40p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -e) [ $# -ge 2 ] || { echo "usage: gate.sh [-e ENV_FILE] RELEASE_SHA" >&2; exit 2; }
        env_file="$2"; shift 2 ;;
    -*) echo "usage: gate.sh [-e ENV_FILE] RELEASE_SHA" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [ $# -ne 1 ]; then echo "usage: gate.sh [-e ENV_FILE] RELEASE_SHA" >&2; exit 2; fi
sha="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then echo "usage: RELEASE_SHA must be 40 hex digits" >&2; exit 2; fi
if [ -n "$env_file" ] && [ ! -r "$env_file" ]; then echo "usage: cannot read ENV_FILE" >&2; exit 2; fi

repo="${GATE_REPO:-$here/../..}"
fetch_images="${FETCH_IMAGES:-$here/fetch-images.sh}"
inspect="${INSPECT_SH:-$here/inspect.sh}"
override="${OVERRIDE_FILE:-$here/docker-compose.override.yaml}"
runbook="${RUNBOOK_FILE:-$here/RUNBOOK.md}"

tmp="$(mktemp -d)" || { echo "usage: cannot create a temporary directory" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

fails=()
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; fails+=("$1"); }

# unquote VALUE: the value as docker compose reads an env file line. Surrounding
# whitespace is dropped; a quoted value ends at its closing quote (a comment may
# follow); an unquoted value loses a " #..." tail, and a value that starts with #
# is empty.
unquote() {
  local v=$1 q rest
  v="${v#"${v%%[![:space:]]*}"}"
  q="${v:0:1}"
  if [ "$q" = '"' ] || [ "$q" = "'" ]; then
    rest="${v:1}"
    v="${rest%%"$q"*}"
  else
    case "$v" in "#"*) v="" ;; esac
    v="${v%%[[:space:]]#*}"
    v="${v%"${v##*[![:space:]]}"}"
  fi
  printf '%s' "$v"
}

# cfg KEY: value of KEY from ENV_FILE (last assignment wins, quotes and CR removed)
# or from the environment. Never echoed by this script.
cfg() {
  local line v
  if [ -n "$env_file" ]; then
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$env_file" | tail -n1 | tr -d '\r')" || true
    [ -n "$line" ] || return 0
    unquote "${line#*=}"
  else
    unquote "${!1:-}"
  fi
}

# is_ipv6 ADDR: plain colon-hex form only (no zone, no embedded IPv4)
is_ipv6() {
  local a=$1 g n=0 dbl=0
  [[ "$a" =~ ^[0-9A-Fa-f:]+$ && "$a" == *:*:* && "$a" != *:::* ]] || return 1
  [[ "$a" == *::* ]] && dbl=1
  [[ "$a" =~ ::.*:: ]] && return 1
  [[ "$a" == :* && "$a" != ::* ]] && return 1
  [[ "$a" == *: && "$a" != *:: ]] && return 1
  local IFS=:
  # shellcheck disable=SC2086
  for g in $a; do
    n=$((n + 1))
    [[ ${#g} -le 4 ]] || return 1
  done
  if [ "$dbl" = 1 ]; then [ "$n" -le 7 ]; else [ "$n" -eq 8 ] && [[ "$a" != :* && "$a" != *: ]]; fi
}

# run_limited CMD...: run with an overall time limit (GATE_INSPECT_TIMEOUT seconds, default 300)
run_limited() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${GATE_INSPECT_TIMEOUT:-300}" "$@"
  else
    echo "error: no timeout command found; inspect.sh cannot be time-limited, so it is not run"
    return 127
  fi
}

echo "== gate.sh: go/no-go before deploy =="

# 1. release sha is on origin/live-updates/v1.4.2
name="release sha is on $BRANCH"
if ! git -C "$repo" fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
  fail "$name" "cannot fetch origin $BRANCH"
elif ! git -C "$repo" rev-parse --verify -q "$sha^{commit}" >/dev/null 2>&1; then
  fail "$name" "commit not found in the checkout"
elif git -C "$repo" merge-base --is-ancestor "$sha" "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
  pass "$name"
else
  fail "$name" "commit is not an ancestor of origin/$BRANCH"
fi

# 2. QA PASS names the sha
name="QA PASS names the release sha"
qa="${QA_RECORD:-}"
if [ -z "$qa" ] || [ ! -r "$qa" ]; then
  fail "$name" "QA_RECORD not set or not readable"
else
  qa_pass=0; qa_fail=0
  while IFS= read -r l; do
    l="${l%$'\r'}"
    if [[ "$l" =~ ^QA:[[:space:]]+(PASS|FAIL)[[:space:]]+@[[:space:]]*([0-9a-fA-F]{7,40})([^0-9a-fA-F]|$) ]]; then
      s="$(printf '%s' "${BASH_REMATCH[2]}" | tr 'A-F' 'a-f')"
      case "$sha" in "$s"*) [ "${BASH_REMATCH[1]}" = PASS ] && qa_pass=1 || qa_fail=1 ;; esac
    fi
  done <"$qa"
  if [ "$qa_fail" = 1 ]; then fail "$name" "the record has a QA: FAIL line for this sha"
  elif [ "$qa_pass" = 1 ]; then pass "$name"
  else fail "$name" "no 'QA: PASS @ <sha>' line for this sha"; fi
fi

# 3. archive sha256 matches the build notes (fetch-images.sh does the compare; no load)
name="image archive sha256 matches the build notes"
want="${IMAGE_SHA256:-}"
notes_tar=""
if [ -n "${BUILD_NOTES:-}" ] && [ -r "${BUILD_NOTES}" ]; then
  notes_tar="$(sed -n 's/^Tar sha256:[[:space:]]*\([0-9a-fA-F]\{64\}\)[[:space:]]*$/\1/p' "$BUILD_NOTES" | head -n1 | tr 'A-F' 'a-f')"
fi
[ -n "$want" ] || want="$notes_tar"
want="$(printf '%s' "$want" | tr 'A-F' 'a-f')"
if [ -z "${IMAGE_TAR:-}" ] || [ ! -f "${IMAGE_TAR}" ]; then
  fail "$name" "IMAGE_TAR not set or not a file"
elif [ -n "$notes_tar" ] && [ "$notes_tar" != "$want" ]; then
  fail "$name" "IMAGE_SHA256 differs from the Tar sha256 line in BUILD_NOTES"
elif [ -z "$want" ]; then
  fail "$name" "no IMAGE_SHA256 and no 'Tar sha256:' line in BUILD_NOTES"
else
  mkdir "$tmp/img"
  if SKIP_LOAD=1 bash "$fetch_images" "$IMAGE_TAR" "$want" "$tmp/img" >"$tmp/fetch.out" 2>&1; then
    pass "$name"
  else
    fail "$name" "$(grep -E '^ERROR:' "$tmp/fetch.out" | tail -n1 | cut -c1-200)"
  fi
  rm -rf "$tmp/img"
fi

# 3b. the archive is bound to the release sha. Preferred: every image in the archive
# carries the label plane-fork-build=<sha> that build.sh sets (read from the archive's
# manifest and image configs; nothing is loaded). Also: if BUILD_NOTES is given, its
# "SHA verified: <sha>" line must name the release sha.
name="image archive is bound to the release sha"
label_state=none; notes_state=none; detail=""
if [ -n "${IMAGE_TAR:-}" ] && [ -f "$IMAGE_TAR" ]; then
  man="$(tar -xOf "$IMAGE_TAR" manifest.json 2>/dev/null | head -c 1048576)"
  cfgs="$(printf '%s' "$man" | grep -oE '"Config"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/^"Config"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  ncfg=0; nok=0; nbad=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [[ "$c" =~ ^[A-Za-z0-9._/-]+$ && "$c" != *..* && "$c" != /* ]] || { nbad=$((nbad + 1)); ncfg=$((ncfg + 1)); continue; }
    ncfg=$((ncfg + 1))
    lab="$(tar -xOf "$IMAGE_TAR" -- "$c" 2>/dev/null | head -c 4194304 | grep -oE '"plane-fork-build"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
    if [ "$lab" = "$sha" ]; then nok=$((nok + 1)); elif [ -n "$lab" ]; then nbad=$((nbad + 1)); fi
  done <<<"$cfgs"
  if [ "$ncfg" -ge 3 ] && [ "$nok" = "$ncfg" ]; then label_state=ok
  elif [ "$nbad" -gt 0 ]; then label_state=mismatch; detail="$nbad of $ncfg image configs carry another or an unusable build label"
  fi
fi
if [ -n "${BUILD_NOTES:-}" ]; then
  if [ ! -r "$BUILD_NOTES" ]; then notes_state=mismatch; detail="$detail BUILD_NOTES not readable;"
  else
    nv="$(sed -n 's/^SHA verified:[[:space:]]*\([0-9a-fA-F]\{40\}\)[[:space:]].*$/\1/p' "$BUILD_NOTES" | tr 'A-F' 'a-f')"
    if [ -z "$nv" ]; then notes_state=mismatch; detail="$detail BUILD_NOTES has no 'SHA verified: <sha>' line;"
    elif [ "$(printf '%s\n' "$nv" | grep -vc "^$sha$")" -gt 0 ]; then notes_state=mismatch; detail="$detail BUILD_NOTES names another sha;"
    elif [ -z "$notes_tar" ]; then notes_state=weak; detail="$detail BUILD_NOTES has no 'Tar sha256:' line, so it cannot bind the archive alone;"
    elif [ "$notes_tar" != "$want" ]; then notes_state=weak; detail="$detail BUILD_NOTES Tar sha256 line differs from the archive sha256;"
    else notes_state=ok; fi
  fi
fi
if [ "$label_state" = mismatch ] || [ "$notes_state" = mismatch ]; then fail "$name" "$detail"
elif [ "$label_state" = ok ] || [ "$notes_state" = ok ]; then pass "$name (label=$label_state notes=$notes_state)"
else fail "$name" "archive not bound to the release sha: no plane-fork-build label found in the archive and no usable BUILD_NOTES;$detail"
fi

# 4. RUNBOOK inspection table filled
name="RUNBOOK inspection table filled"
if [ ! -r "$runbook" ]; then
  fail "$name" "RUNBOOK_FILE not readable"
else
  rows=0; empty=0; empties=""
  while IFS= read -r l; do
    l="${l%$'\r'}"
    inner="${l#|}"; inner="${inner%|}"
    item="${inner%|*}"; item="$(printf '%s' "$item" | sed 's/^ *//;s/ *$//')"
    result="$(printf '%s' "${inner##*|}" | sed 's/^ *//;s/ *$//')"
    [ "$item" = Item ] && continue
    case "$item" in -*|"") continue ;; esac
    rows=$((rows + 1))
    if [ -z "$result" ]; then empty=$((empty + 1)); [ "$empty" -le 3 ] && empties="$empties [$item]"; fi
  done < <(awk '/^### Inspection results/{s=1;next} s && /^#/{exit} s && /^\|/' "$runbook")
  if [ "$rows" -eq 0 ]; then fail "$name" "no inspection table found"
  elif [ "$empty" -gt 0 ]; then fail "$name" "$empty of $rows rows have no result, first:$empties"
  else pass "$name ($rows rows)"; fi
fi

# 5. deploy settings
if [ -n "$env_file" ]; then echo "-- settings from the env file (names only) --"; else echo "-- settings from the environment (names only) --"; fi

v="$(cfg LIVE_EVENTS_TRUSTED_PROXIES)"
name="LIVE_EVENTS_TRUSTED_PROXIES is set and valid CIDRs"
if [ -z "$(printf '%s' "$v" | tr -d ' ,')" ]; then
  fail "$name" "empty or unset"
else
  bad=0; n=0
  IFS=',' read -r -a ents <<<"$v"
  for e in "${ents[@]}"; do
    e="$(printf '%s' "$e" | tr -d ' ')"
    [ -n "$e" ] || continue
    n=$((n + 1))
    addr="${e%%/*}"; pre=""; hasp=0
    case "$e" in */*) hasp=1; pre="${e#*/}" ;; esac
    ok=0
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
      ok=1; max=32
      for i in 1 2 3 4; do [ "$((10#${BASH_REMATCH[$i]}))" -le 255 ] || ok=0; done
    elif is_ipv6 "$addr"; then
      ok=1; max=128
    fi
    if [ "$ok" = 1 ] && [ "$hasp" = 1 ]; then
      # wider ranges would trust nearly every address
      # minimum prefix /8 (IPv4) and /16 (IPv6): wider ranges, such as two /1 halves, trust nearly everything
      if ! [[ "$pre" =~ ^[0-9]{1,3}$ ]] || [ "$((10#$pre))" -gt "$max" ] || [ "$((10#$pre))" -lt "$((max == 32 ? 8 : 16))" ]; then ok=0; fi
    fi
    [ "$ok" = 1 ] || bad=$((bad + 1))
  done
  if [ "$bad" -gt 0 ]; then fail "$name" "$bad of $n entries are not valid single addresses or CIDR ranges (ranges wider than /8 for IPv4 or /16 for IPv6 are refused)"
  else pass "$name ($n entries)"; fi
fi

name="PAGES_REBASE_MAX_HTML_BYTES >= PAGES_API_MAX_HTML_BYTES"
rb="$(cfg PAGES_REBASE_MAX_HTML_BYTES)"; ab="$(cfg PAGES_API_MAX_HTML_BYTES)"
# unset means the code defaults: live 524288, api 262144
[ -n "$rb" ] || rb=524288
[ -n "$ab" ] || ab=262144
if ! [[ "$rb" =~ ^[0-9]{1,15}$ ]] || ! [[ "$ab" =~ ^[0-9]{1,15}$ ]]; then
  fail "$name" "a value is not a positive integer"
elif [ "$((10#$rb))" -lt 1 ] || [ "$((10#$ab))" -lt 1 ]; then
  fail "$name" "a value is not a positive integer"
elif [ "$((10#$rb))" -ge "$((10#$ab))" ]; then pass "$name"
else fail "$name" "rebase limit is below the API limit (live would reject pages the API accepts)"; fi

name="PAGES_REBASE_WORKER_MAX_MB in range 64..4096"
mb="$(cfg PAGES_REBASE_WORKER_MAX_MB)"
if [ -z "$mb" ]; then pass "$name (unset, code default 256)"
elif ! [[ "$mb" =~ ^[0-9]{1,6}$ ]]; then fail "$name" "not an integer"
elif [ "$((10#$mb))" -ge 64 ] && [ "$((10#$mb))" -le 4096 ]; then pass "$name"
else fail "$name" "outside 64..4096"; fi

name="NODE_OPTIONS has no --max-old-space-size"
no="$(cfg NODE_OPTIONS)"
case "$no" in
  *max-old-space-size*|*max_old_space_size*) fail "$name" "NODE_OPTIONS sets the old-space limit; remove it for live" ;;
  *) pass "$name" ;;
esac

name="LIVE_SERVER_SECRET_KEY is set and not the placeholder"
sk="$(cfg LIVE_SERVER_SECRET_KEY)"
if [ -z "$sk" ]; then fail "$name" "empty or unset"
elif [ -z "$(printf '%s' "$sk" | tr -d '[:space:]')" ]; then fail "$name" "empty or unset"
elif [[ "${sk,,}" == *"$PLACEHOLDER"* ]]; then fail "$name" "is or contains the shipped placeholder"
else pass "$name"; fi
sk=""

# 6. inspect.sh preflight (reused as is)
name="inspect.sh preflight passes"
if [ -z "${PLANE_CTID:-}" ] || [ -z "${PLANE_APP_DIR:-}" ]; then
  fail "$name" "set PLANE_CTID and PLANE_APP_DIR"
else
  rc=0
  if ! [[ "$PLANE_CTID" =~ ^[0-9]+$ ]]; then
    rc=126; echo "error: PLANE_CTID must be numeric (not sent)" >"$tmp/inspect.out"
  elif ! [[ "$PLANE_APP_DIR" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
    rc=126; echo "error: PLANE_APP_DIR must be an absolute path of safe characters (not sent)" >"$tmp/inspect.out"
  elif [ -n "${PVE_HOST:-}" ] && ! [[ "$PVE_HOST" =~ ^[A-Za-z0-9_][A-Za-z0-9._@:-]*$ ]]; then
    rc=126; echo "error: PVE_HOST has unexpected characters (not used)" >"$tmp/inspect.out"
  elif [ -n "${PVE_HOST:-}" ]; then
    # shellcheck disable=SC2029 # expanded on this side on purpose, as in RUNBOOK step 1
    remote="PLANE_CTID=$(printf '%q' "$PLANE_CTID") PLANE_APP_DIR=$(printf '%q' "$PLANE_APP_DIR") bash -s"
    run_limited ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -- "$PVE_HOST" "$remote" <"$inspect" >"$tmp/inspect.out" 2>&1 || rc=$?
  elif command -v pct >/dev/null 2>&1; then
    run_limited bash "$inspect" >"$tmp/inspect.out" 2>&1 || rc=$?
  else
    rc=127; echo "pct not found and PVE_HOST not set" >"$tmp/inspect.out"
  fi
  if [ "$rc" = 0 ] && grep -q '^RESULT: no STOP lines' "$tmp/inspect.out"; then
    pass "$name"
  else
    [ "$rc" = 124 ] && echo "(inspect.sh timed out)" >>"$tmp/inspect.out"
    fail "$name" "exit $rc; $( (grep -E '^(STOP|error|WARN):' "$tmp/inspect.out" || tail -n1 "$tmp/inspect.out") | head -n3 | cut -c1-200 | tr '\n' ' ')"
  fi
fi

# 7. rollback path
name="rollback L1: the five flag lines are present in the override"
if [ ! -r "$override" ]; then
  fail "$name" "override file not readable"
else
  on="$(grep -cE '^ +(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): "1"$' "$override")"
  if [ "$on" = 5 ]; then pass "$name"
  else fail "$name" "expected 5 flag lines set to \"1\" (3 LIVE_EVENTS_ENABLED, 2 PAGES_API_ENABLED), found $on"; fi
fi
name="rollback L2: STOCK_RELEASE names the stock image tag"
sr="${STOCK_RELEASE:-}"
if [ -z "$sr" ]; then fail "$name" "STOCK_RELEASE not set"
elif ! [[ "$sr" =~ ^[A-Za-z0-9._-]+$ ]]; then fail "$name" "STOCK_RELEASE has unexpected characters"
elif [[ "$sr" == *-live.* ]]; then fail "$name" "STOCK_RELEASE looks like a fork tag"
else pass "$name"; fi

echo
if [ "${#fails[@]}" -eq 0 ]; then
  echo "RESULT: GO"
  exit 0
fi
echo "RESULT: NO-GO (${#fails[@]} failing)"
for f in "${fails[@]}"; do echo "  - $f"; done
exit 1
