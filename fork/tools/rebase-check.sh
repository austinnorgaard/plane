#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# rebase-check.sh - before moving the fork onto a new upstream tag (PLN-46), show what
# the move would cost. Read-only: no checkout, no branch, no commit, no change to the
# working tree (the trial merge is git merge-tree, which writes only loose objects).
#
# Usage:
#   fork/tools/rebase-check.sh [--base <ref>] [--snapshot <file>] [--ignore-lines] [--write] <upstream-tag>
#
#   <upstream-tag>  the makeplane/plane tag to check against, for example v1.4.4. It must
#                   exist locally: git fetch upstream tag <tag> --no-tags
#   --base          the fork commit to check (default: HEAD).
#   --snapshot      the call-site snapshot to compare with (default: the newest
#                   fork/tools/callsites.v*.txt).
#   --ignore-lines  compare call sites without line numbers (shows only added, removed or
#                   changed call sites, not the ones that only moved).
#   --write         also save the regenerated snapshot as fork/tools/callsites.<tag>.txt.
#
# Output, in three parts:
#   1. every upstream file listed in fork/PATCHES.md, with its state against the tag:
#      CONFLICT (the trial merge conflicts in it), CHANGED (upstream changed it, the
#      merge is clean: re-read the fork patch anyway), same (upstream did not touch it),
#      or GONE (upstream deleted or renamed it).
#   2. conflicts in files that PATCHES.md does not list (PATCHES.md is missing a line,
#      or a fork-only file collides with a new upstream file).
#   3. the issue_activity call-site snapshot regenerated from the tag, as a diff against
#      the current snapshot (fork/tools/CALLSITES.md says what to do with each change).
#
# Exit status: 0 nothing to do, 1 conflicts or a call-site diff, 2 usage or setup error.
# Needs git >= 2.38 (merge-tree --write-tree) and python3.

set -euo pipefail

die() {
  echo "rebase-check: $*" >&2
  exit 2
}

usage() {
  sed -n '7,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

base=HEAD
snapshot=""
write=0
ignore_lines=0
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage; base=$2; shift 2 ;;
    --snapshot) [ $# -ge 2 ] || usage; snapshot=$2; shift 2 ;;
    --write) write=1; shift ;;
    --ignore-lines) ignore_lines=1; shift ;;
    -h | --help) usage ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$tag" ] || usage; tag=$1; shift ;;
  esac
done
[ -n "$tag" ] || usage

root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
cd "$root"
patches=fork/PATCHES.md
[ -f "$patches" ] || die "$patches not found"

py=python3
command -v "$py" >/dev/null 2>&1 || py=python
command -v "$py" >/dev/null 2>&1 || die "python3 not found"

# A tag normally; any commit-ish works (for example upstream/preview, to look ahead).
tag_sha=$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}" || git rev-parse --verify --quiet "$tag^{commit}") ||
  die "$tag not found locally; run: git fetch upstream tag $tag --no-tags"
base_sha=$(git rev-parse --verify --quiet "$base^{commit}") || die "unknown --base $base"
merge_base=$(git merge-base "$base_sha" "$tag_sha") || die "no merge base between $base and $tag"

if [ -z "$snapshot" ]; then
  snapshot=$(find fork/tools -maxdepth 1 -name 'callsites.v*.txt' | sort -V | tail -n 1)
fi
[ -n "$snapshot" ] && [ -f "$snapshot" ] || die "no call-site snapshot found (use --snapshot)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "fork:       $base ($(git rev-parse --short "$base_sha"))"
echo "upstream:   $tag ($(git rev-parse --short "$tag_sha"))"
echo "merge base: $(git describe --tags --always "$merge_base" 2>/dev/null) ($(git rev-parse --short "$merge_base"))"
echo

# The upstream files PATCHES.md lists: backticked repo paths in the part above "New files".
# Brace lists (a/{b,c}.ts) are expanded; a ".../name" path is matched by suffix against the
# files of the fork commit.
git ls-tree -r --name-only "$base_sha" >"$tmp/files"
"$py" - "$patches" "$tmp/files" <<'PY' | tr -d '\r' >"$tmp/patched"
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
files = [ln.rstrip("\n") for ln in open(sys.argv[2], encoding="utf-8")]
known = set(files)
text = text.split("\nNew files", 1)[0]


def expand(tok):
    m = re.search(r"\{([^{}]*)\}", tok)
    if not m:
        return [tok]
    out = []
    for part in m.group(1).split(","):
        out.extend(expand(tok[: m.start()] + part + tok[m.end() :]))
    return out


seen = []
for tok in re.findall(r"`([^`\s]+)`", text):
    for path in expand(tok):
        if path.startswith(".../"):
            tail = path[3:]
            hits = [f for f in files if f.endswith(tail)]
            if len(hits) == 1:
                path = hits[0]
        if "/" not in path or path.startswith(("http", "plane:")):
            continue
        if path in known or re.match(r"^[\w.()\[\]-]+(/[\w.()\[\]-]+)+$", path):
            if path not in seen:
                seen.append(path)
for path in seen:
    print(path)
PY

# Trial merge of the tag into the fork commit. Exit 1 means conflicts, which is expected.
set +e
git merge-tree --write-tree --name-only --no-messages "$base_sha" "$tag_sha" >"$tmp/merge"
merge_rc=$?
set -e
[ "$merge_rc" -le 1 ] || die "git merge-tree failed (exit $merge_rc); git >= 2.38 is needed"
tail -n +2 "$tmp/merge" | sed '/^$/d' | sort -u >"$tmp/conflicts"
git diff --name-only "$merge_base" "$tag_sha" | sort -u >"$tmp/upstream_changed"

status=0
n_conflict=0
n_changed=0
echo "== 1. PATCHES.md files against $tag"
while IFS= read -r path; do
  if grep -qxF -- "$path" "$tmp/conflicts"; then
    state=CONFLICT
    n_conflict=$((n_conflict + 1))
  elif ! git cat-file -e "$tag_sha:$path" 2>/dev/null; then
    if git cat-file -e "$merge_base:$path" 2>/dev/null; then
      state=GONE
      n_changed=$((n_changed + 1))
    else
      continue # a fork-only file listed for context; section 2 catches a collision
    fi
  elif grep -qxF -- "$path" "$tmp/upstream_changed"; then
    state=CHANGED
    n_changed=$((n_changed + 1))
  else
    state=same
  fi
  printf '  %-8s %s\n' "$state" "$path"
done <"$tmp/patched"
echo "  ($n_conflict conflict(s), $n_changed changed or gone upstream)"
[ "$n_conflict" -eq 0 ] || status=1
echo

echo "== 2. conflicts in files PATCHES.md does not list"
grep -vxF -f "$tmp/patched" "$tmp/conflicts" >"$tmp/unlisted" || true
if [ -s "$tmp/unlisted" ]; then
  sed 's/^/  CONFLICT /' "$tmp/unlisted"
  status=1
else
  echo "  none"
fi
echo

# Regenerate the call-site snapshot from the tag's api tree (git archive into a temp dir,
# so nothing is checked out) and diff it against the current snapshot.
echo "== 3. issue_activity call sites: $snapshot vs $tag"
mkdir -p "$tmp/tree"
git archive "$tag_sha" apps/api/plane | tar -x -C "$tmp/tree"
"$py" fork/tools/callsites.py --root "$tmp/tree" \
  --header "source: upstream makeplane/plane $tag ($(git rev-parse --short=10 "$tag_sha")); regenerate: fork/tools/rebase-check.sh --write $tag" \
  | tr -d '\r' >"$tmp/snapshot"
grep -v '^#' "$snapshot" | tr -d '\r' | sed '/^$/d' >"$tmp/old_rows"
grep -v '^#' "$tmp/snapshot" | sed '/^$/d' >"$tmp/new_rows"
if [ "$ignore_lines" -eq 1 ]; then
  for f in old_rows new_rows; do
    sed 's/^\([^ ]*\):[0-9][0-9]* | /\1 | /' "$tmp/$f" >"$tmp/$f.nl" && mv "$tmp/$f.nl" "$tmp/$f"
  done
fi
if diff -u --label "$snapshot" --label "$tag" "$tmp/old_rows" "$tmp/new_rows" >"$tmp/callsite_diff"; then
  echo "  same $(wc -l <"$tmp/new_rows" | tr -d ' ') call sites"
else
  cat "$tmp/callsite_diff"
  echo "  snapshot: $(wc -l <"$tmp/old_rows" | tr -d ' ') call sites, $tag: $(wc -l <"$tmp/new_rows" | tr -d ' ')"
  echo "  (rows edited by hand to the fork's text show up here too; see fork/tools/CALLSITES.md)"
  status=1
fi
if [ "$write" -eq 1 ]; then
  out="fork/tools/callsites.${tag//\//-}.txt"
  cp "$tmp/snapshot" "$out"
  echo "  wrote $out"
fi

exit "$status"
