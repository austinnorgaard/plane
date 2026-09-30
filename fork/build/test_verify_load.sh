#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# test_verify_load.sh - test verify-load.sh with stubbed podman
#
# Creates temporary files and directories, runs verify-load.sh with a
# fake podman on PATH, and verifies it handles good and bad hashes correctly.
#
# Exit 0 if all tests pass; exit 1 if any test fails.

set -u

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

test_count=0
pass_count=0
fail_count=0

# Create a temporary directory for test artifacts
test_dir=$(mktemp -d)
trap "rm -rf '$test_dir'" EXIT

# Make sure verify-load.sh is in the same directory as this test
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify_load="$script_dir/verify-load.sh"

if [ ! -f "$verify_load" ]; then
  echo -e "${RED}ERROR: verify-load.sh not found at $verify_load${NC}" >&2
  exit 1
fi

if [ ! -x "$verify_load" ]; then
  chmod +x "$verify_load"
fi

# Create a fake podman command
podman_fake="$test_dir/podman"
cat > "$podman_fake" << 'EOF'
#!/bin/bash
# Fake podman that accepts load command and images query
case "$1" in
  load)
    # Accept podman load -i <file>
    exit 0
    ;;
  images)
    # Return the expected image prefixes
    echo "localhost/plane-fork-web:v1.4.2-live.1"
    echo "localhost/plane-fork-live:v1.4.2-live.1"
    echo "localhost/plane-fork-backend:v1.4.2-live.1"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$podman_fake"

# Test function
run_test() {
  local test_name="$1"
  local tar_file="$2"
  local sha256_file="$3"
  local expect_pass="$4"

  ((test_count++))

  # Run verify-load.sh with fake podman on PATH
  export PATH="$test_dir:$PATH"

  if "$verify_load" "$tar_file" "$sha256_file" > /dev/null 2>&1; then
    result=0
  else
    result=1
  fi

  if [ "$expect_pass" -eq 1 ]; then
    # Should pass
    if [ $result -eq 0 ]; then
      echo -e "${GREEN}✓${NC} $test_name (passed as expected)"
      ((pass_count++))
      return 0
    else
      echo -e "${RED}✗${NC} $test_name (expected pass but failed)"
      ((fail_count++))
      return 1
    fi
  else
    # Should fail
    if [ $result -ne 0 ]; then
      echo -e "${GREEN}✓${NC} $test_name (failed as expected)"
      ((pass_count++))
      return 0
    else
      echo -e "${RED}✗${NC} $test_name (expected fail but passed)"
      ((fail_count++))
      return 1
    fi
  fi
}

# Test 1: Good hash should pass
echo "Test 1: Verify with correct hash..."
test_tar1="$test_dir/test1.tar"
test_sha1="$test_dir/test1.sha256"
test_content="test content for tar file"
echo -n "$test_content" > "$test_tar1"
sha256sum "$test_tar1" > "$test_sha1"
run_test "correct hash" "$test_tar1" "$test_sha1" 1

# Test 2: Bad hash should fail
echo "Test 2: Verify with incorrect hash..."
test_tar2="$test_dir/test2.tar"
test_sha2="$test_dir/test2.sha256"
echo -n "$test_content" > "$test_tar2"
# Create a sha256 file with wrong hash
echo "0000000000000000000000000000000000000000000000000000000000000000  test2.tar" > "$test_sha2"
run_test "incorrect hash" "$test_tar2" "$test_sha2" 0

# Test 3: Missing tar file should fail
echo "Test 3: Missing tar file..."
test_sha3="$test_dir/test3.sha256"
echo "d1394a0f30a2b50fbef9f11192ec13b8f43d5a5a4d55db3ecef4e0cfae4e1f36  missing.tar" > "$test_sha3"
run_test "missing tar file" "$test_dir/missing.tar" "$test_sha3" 0

# Test 4: Missing sha256 file should fail
echo "Test 4: Missing sha256 file..."
test_tar4="$test_dir/test4.tar"
echo -n "$test_content" > "$test_tar4"
run_test "missing sha256 file" "$test_tar4" "$test_dir/missing.sha256" 0

# Test 5: Empty sha256 file should fail
echo "Test 5: Empty sha256 file..."
test_tar5="$test_dir/test5.tar"
test_sha5="$test_dir/test5.sha256"
echo -n "$test_content" > "$test_tar5"
touch "$test_sha5"  # Empty file
run_test "empty sha256 file" "$test_tar5" "$test_sha5" 0

# Summary
echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Total:  $test_count"
echo -e "Passed: ${GREEN}$pass_count${NC}"
echo -e "Failed: ${RED}$fail_count${NC}"
echo "========================================="

if [ $fail_count -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
