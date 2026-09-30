#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# verify-load.sh TAR SHA256_FILE [N]
#
# Verifies the tar archive's checksum, loads it into podman, and checks
# that the three exact references localhost/plane-fork-{web,live,api}:v1.4.2-live.N
# exist. N is the optional third argument; if omitted it is taken from a tar
# name of the form plane-fork-live.<N>.tar.
#
# Exit 0 if all checks pass; exit 1 if any check fails.
#
# Usage:
#   verify-load.sh plane-fork-live.1.tar plane-fork-live.1.sha256
#   verify-load.sh /path/to/plane-fork-live.1.tar /path/to/plane-fork-live.1.sha256

set -u

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: verify-load.sh TAR SHA256_FILE [N]" >&2
  exit 1
fi

tar_file="$1"
sha256_file="$2"
n="${3:-}"

if [ -z "$n" ]; then
  base="$(basename "$tar_file")"
  case "$base" in
    plane-fork-live.*.tar) n="${base#plane-fork-live.}"; n="${n%.tar}" ;;
  esac
fi

if ! [[ "$n" =~ ^[0-9]+$ ]]; then
  echo "ERROR: build number N unknown: pass it as the third argument or name the tar plane-fork-live.<N>.tar" >&2
  exit 1
fi
image_tag="v1.4.2-live.$n"

# Verify tar file exists
if [ ! -f "$tar_file" ]; then
  echo "ERROR: tar file not found: $tar_file" >&2
  exit 1
fi

# Verify sha256 file exists
if [ ! -f "$sha256_file" ]; then
  echo "ERROR: sha256 file not found: $sha256_file" >&2
  exit 1
fi

# Extract the expected hash from the sha256 file
# Format: <hash>  <filename>
if ! expected_hash=$(awk '{print $1; exit}' "$sha256_file"); then
  echo "ERROR: failed to read sha256 file: $sha256_file" >&2
  exit 1
fi

if [ -z "$expected_hash" ]; then
  echo "ERROR: sha256 file is empty: $sha256_file" >&2
  exit 1
fi

if ! [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: sha256 file does not start with a 64-character hex digest: $sha256_file" >&2
  exit 1
fi
expected_hash="$(printf '%s' "$expected_hash" | tr 'A-F' 'a-f')"

echo "Verifying sha256 of $tar_file..."
echo "Expected: $expected_hash"

# Compute actual hash
actual_hash=$(sha256sum "$tar_file" | awk '{print $1}')
echo "Actual:   $actual_hash"

if [ "$expected_hash" != "$actual_hash" ]; then
  echo "ERROR: sha256 mismatch!" >&2
  exit 1
fi

echo "sha256 verified"

# Load the images
echo "Loading images from $tar_file..."
if ! podman load -i "$tar_file"; then
  echo "ERROR: podman load failed" >&2
  exit 1
fi

echo "Images loaded"

# Verify the three exact references exist
echo "Verifying image tags ($image_tag)..."
expected_refs=(
  "localhost/plane-fork-web:$image_tag"
  "localhost/plane-fork-live:$image_tag"
  "localhost/plane-fork-api:$image_tag"
)

failed=0
for ref in "${expected_refs[@]}"; do
  if podman image exists "$ref"; then
    echo "  OK $ref found"
  else
    echo "  MISSING $ref" >&2
    failed=1
  fi
done

if [ $failed -eq 1 ]; then
  echo "ERROR: one or more image tags missing" >&2
  exit 1
fi

echo "All checks passed"
exit 0
