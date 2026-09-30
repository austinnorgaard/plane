#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# verify-load.sh TAR SHA256_FILE
#
# Verifies the tar archive's checksum, loads it into podman, and checks
# that the three expected image tags exist.
#
# Exit 0 if all checks pass; exit 1 if any check fails.
#
# Usage:
#   verify-load.sh plane-fork-live.1.tar plane-fork-live.1.sha256
#   verify-load.sh /path/to/plane-fork-live.1.tar /path/to/plane-fork-live.1.sha256

set -u

if [ $# -ne 2 ]; then
  echo "usage: verify-load.sh TAR SHA256_FILE" >&2
  exit 1
fi

tar_file="$1"
sha256_file="$2"

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

# Verify the three tags exist
echo "Verifying image tags..."
expected_tags=(
  "localhost/plane-fork-web"
  "localhost/plane-fork-live"
  "localhost/plane-fork-backend"
)

failed=0
for tag_prefix in "${expected_tags[@]}"; do
  if podman images --filter "reference=$tag_prefix" --quiet | grep -q .; then
    echo "  ✓ $tag_prefix found"
  else
    echo "  ✗ $tag_prefix NOT FOUND" >&2
    failed=1
  fi
done

if [ $failed -eq 1 ]; then
  echo "ERROR: one or more image tags missing" >&2
  exit 1
fi

echo "All checks passed"
exit 0
