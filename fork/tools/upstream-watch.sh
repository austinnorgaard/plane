#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# upstream-watch.sh - what changed upstream since a date (PLN-73), as Markdown for the
# DAILY. Read-only: GET calls through the gh CLI only (gh auth login once; a public repo
# needs no scopes).
#
# Usage:
#   fork/tools/upstream-watch.sh [--since YYYY-MM-DD] [--repo owner/name] [<number> ...]
#
#   --since   start date, UTC (default: yesterday).
#   --repo    upstream repository (default: makeplane/plane).
#   <number>  issues or pull requests to watch (default: the list the fork tracks, below).
#
# Output:
#   - every release published since the date (tag, name, date, prerelease flag, URL);
#   - each watched issue or PR: its current state (open, closed with reason, merged),
#     the state events since the date (closed, reopened, merged, labeled, ...) and the
#     number of new comments since the date. Items with no change are listed on one line.
#
# Exit status: 0 nothing new, 1 something changed (handy for a cron mail), 2 error.

set -euo pipefail

# The upstream items the fork tracks (PLN-73): the live-updates and pages work and the
# bugs the fork patches around.
DEFAULT_ITEMS=(9666 9779 9780 7944 9757 8986 7319 8598 9511)

die() {
  echo "upstream-watch: $*" >&2
  exit 2
}

repo=makeplane/plane
since=""
items=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || die "--since needs a date"; since=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || die "--repo needs owner/name"; repo=$2; shift 2 ;;
    -h | --help) sed -n '7,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] || die "not an issue number: $1"; items+=("$1"); shift ;;
  esac
done
[ "${#items[@]}" -gt 0 ] || items=("${DEFAULT_ITEMS[@]}")
if [ -z "$since" ]; then
  since=$(date -u -d yesterday +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
fi
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--since must be YYYY-MM-DD"
command -v gh >/dev/null 2>&1 || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
ts="${since}T00:00:00Z"
changed=0

echo "### Upstream watch: $repo since $since"
echo

echo "**Releases**"
releases=$(gh api "repos/$repo/releases?per_page=50" --jq "
  .[] | select(.published_at != null and .published_at >= \"$ts\")
  | \"- \(.tag_name)\(if .name and .name != .tag_name then \" (\" + .name + \")\" else \"\" end), \(.published_at[0:10])\(if .prerelease then \", prerelease\" else \"\" end): \(.html_url)\"") ||
  die "cannot read the releases of $repo"
if [ -n "$releases" ]; then
  echo "$releases"
  changed=1
else
  echo "- none"
fi
echo

echo "**Watched issues and PRs**"
quiet=()
for n in "${items[@]}"; do
  item=$(gh api "repos/$repo/issues/$n" --jq '
    [ (if .pull_request then "PR" else "issue" end),
      (if .pull_request.merged_at then "merged " + .pull_request.merged_at[0:10]
       elif .state == "closed" then "closed" + (if .state_reason then " (" + .state_reason + ")" else "" end) + " " + (.closed_at // "")[0:10]
       else "open" end),
      .title, .html_url ] | @tsv') || {
    echo "- #$n: cannot read it"
    continue
  }
  IFS=$'\t' read -r kind state title url <<<"$item"
  events=$(gh api "repos/$repo/issues/$n/events?per_page=100" --paginate --jq "
    .[] | select(.created_at >= \"$ts\")
    | select(.event | test(\"^(closed|reopened|merged|labeled|unlabeled|milestoned|demilestoned|ready_for_review|convert_to_draft|renamed|locked|unlocked)$\"))
    | \"\(.event)\(if .label then \" \" + .label.name else \"\" end) \(.created_at[0:10])\"" | paste -sd ',' - | sed 's/,/, /g') || events=""
  comments=$(gh api "repos/$repo/issues/$n/comments?since=$ts&per_page=100" --paginate --jq 'length' |
    awk '{ s += $1 } END { print s + 0 }') || comments=0
  if [ -z "$events" ] && [ "$comments" -eq 0 ]; then
    quiet+=("#$n ($state)")
    continue
  fi
  changed=1
  line="- $kind #$n, $state: $title ($url)"
  [ -z "$events" ] || line+="; events: $events"
  [ "$comments" -eq 0 ] || line+="; $comments new comment(s)"
  echo "$line"
done
if [ "${#quiet[@]}" -gt 0 ]; then
  (IFS=,; echo "- no change: ${quiet[*]}" | sed 's/,/, /g')
fi

exit "$changed"
