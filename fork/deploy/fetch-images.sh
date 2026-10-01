#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# fetch-images.sh SOURCE EXPECTED_SHA256 [DEST_DIR]
#
# Fetches the fork image archive (plane-fork-live.<N>.tar, written by
# fork/build/build.sh), verifies its sha256 against a value you pass in, and
# hands off to fork/build/verify-load.sh. It stops at the first failure and
# never leaves an unverified archive under its final name.
#
#   SOURCE           an https:// URL (for example a release asset of the fork),
#                    a file:// URL, or a local path.
#   EXPECTED_SHA256  64 hex digits. Take it from the build output, NOT from the
#                    place the archive is downloaded from. May also be given
#                    in the environment variable FETCH_EXPECTED_SHA256.
#   DEST_DIR         where the archive is stored. Default: the current directory.
#
# Environment (all optional):
#   FORK_N             build number, passed to verify-load.sh. Needed only if the
#                      archive name is not plane-fork-live.<N>.tar.
#   SKIP_LOAD=1        verify and store only; do not run verify-load.sh. A
#                      plane-fork-live.<N>.sha256 file is written next to the
#                      archive so that verify-load.sh can be run later, on
#                      another machine, with both files copied over.
#   FETCH_ALLOW_HTTP=1 also accept plain http:// (for local tests only).
#   VERIFY_LOAD        path of verify-load.sh (default: ../build/verify-load.sh
#                      relative to this script). This script RUNS whatever
#                      VERIFY_LOAD names, so it is an operator-chosen script:
#                      only set it to a file you trust.
#   CONTAINER_ENGINE   passed through to verify-load.sh (podman or docker).
#
# Nothing in this script needs a credential: the fork is public, so release
# assets download anonymously. Exit 0 only if the checksum matched and
# (unless SKIP_LOAD=1) verify-load.sh passed.

set -u
set -o pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  echo "usage: fetch-images.sh SOURCE EXPECTED_SHA256 [DEST_DIR]" >&2
  exit 1
fi

source_ref="$1"
expected="${2:-${FETCH_EXPECTED_SHA256:-}}"
dest_dir="${3:-.}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify_load="${VERIFY_LOAD:-$here/../build/verify-load.sh}"

[ -n "$expected" ] || die "expected sha256 not given (second argument or FETCH_EXPECTED_SHA256)"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "expected sha256 must be 64 hex digits"
expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"

# Name of the archive: last path segment of SOURCE without query or fragment.
name="${source_ref%%[?#]*}"
name="${name##*/}"
[[ "$name" =~ ^[A-Za-z0-9._-]+\.tar$ ]] || die "SOURCE must end in a plain archive name like plane-fork-live.<N>.tar (got '$name')"

mkdir -p "$dest_dir" || die "cannot create $dest_dir"
final="$dest_dir/$name"
part="$(mktemp "$dest_dir/.$name.part.XXXXXX")" || die "cannot create a temporary file in $dest_dir"
trap 'rm -f "$part"' EXIT

case "$source_ref" in
  https://*) echo "Downloading $name..."
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
      --connect-timeout 30 --speed-limit 1000 --speed-time 60 -o "$part" "$source_ref" \
      || die "download failed" ;;
  http://*)
    [ "${FETCH_ALLOW_HTTP:-}" = 1 ] || die "plain http is refused (set FETCH_ALLOW_HTTP=1 for local tests)"
    curl -fsSL --proto '=http' --connect-timeout 30 -o "$part" "$source_ref" || die "download failed" ;;
  file://*)
    curl -fsS --proto '=file' -o "$part" "$source_ref" || die "cannot read $source_ref" ;;
  *://*) die "unsupported URL scheme" ;;
  *)
    [ -f "$source_ref" ] || die "file not found: $source_ref"
    cp -- "$source_ref" "$part" || die "copy failed" ;;
esac

[ -s "$part" ] || die "downloaded file is empty"

actual="$(sha256sum "$part" | awk '{print $1}')"
echo "Expected: $expected"
echo "Actual:   $actual"
if [ "$expected" != "$actual" ]; then
  die "sha256 mismatch: archive discarded, nothing loaded"
fi
echo "sha256 verified"

mv -f -- "$part" "$final" || die "cannot move archive into place"
sha_file="${final%.tar}.sha256"
printf '%s  %s\n' "$expected" "$name" >"$sha_file" || die "cannot write $sha_file"

if [ "${SKIP_LOAD:-}" = 1 ]; then
  echo "Stored $final and $sha_file; load skipped (SKIP_LOAD=1)"
  exit 0
fi

[ -f "$verify_load" ] || die "verify-load.sh not found at $verify_load"
if [ -n "${FORK_N:-}" ]; then
  exec bash "$verify_load" "$final" "$sha_file" "$FORK_N"
fi
exec bash "$verify_load" "$final" "$sha_file"
