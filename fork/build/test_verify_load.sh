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

# Create a fake podman command. `image exists REF` succeeds only if REF is a
# line of $FAKE_PODMAN_IMAGES (default: the three correct references for .1).
podman_fake="$test_dir/podman"
cat > "$podman_fake" << 'EOF'
#!/bin/bash
list="${FAKE_PODMAN_IMAGES:-localhost/plane-fork-web:v1.4.2-live.1
localhost/plane-fork-live:v1.4.2-live.1
localhost/plane-fork-api:v1.4.2-live.1}"
case "$1 $2" in
  "load -i")
    exit 0
    ;;
  "image exists")
    printf '%s\n' "$list" | grep -qxF -- "$3"
    exit $?
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$podman_fake"
export PATH="$test_dir:$PATH"

# Test function
run_test() {
  local test_name="$1"
  local tar_file="$2"
  local sha256_file="$3"
  local expect_pass="$4"
  local n_arg="${5:-}"

  ((test_count++))

  # Run verify-load.sh with fake podman on PATH
  if "$verify_load" "$tar_file" "$sha256_file" $n_arg > /dev/null 2>&1; then
    result=0
  else
    result=1
  fi

  if [ "$expect_pass" -eq 1 ]; then
    # Should pass
    if [ $result -eq 0 ]; then
      echo -e "${GREEN}PASS${NC} $test_name (passed as expected)"
      ((pass_count++))
      return 0
    else
      echo -e "${RED}FAIL${NC} $test_name (expected pass but failed)"
      ((fail_count++))
      return 1
    fi
  else
    # Should fail
    if [ $result -ne 0 ]; then
      echo -e "${GREEN}PASS${NC} $test_name (failed as expected)"
      ((pass_count++))
      return 0
    else
      echo -e "${RED}FAIL${NC} $test_name (expected fail but passed)"
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
run_test "correct hash" "$test_tar1" "$test_sha1" 1 1

# Test 2: Bad hash should fail
echo "Test 2: Verify with incorrect hash..."
test_tar2="$test_dir/test2.tar"
test_sha2="$test_dir/test2.sha256"
echo -n "$test_content" > "$test_tar2"
# Create a sha256 file with wrong hash
echo "0000000000000000000000000000000000000000000000000000000000000000  test2.tar" > "$test_sha2"
run_test "incorrect hash" "$test_tar2" "$test_sha2" 0 1

# Test 3: Missing tar file should fail
echo "Test 3: Missing tar file..."
test_sha3="$test_dir/test3.sha256"
echo "d1394a0f30a2b50fbef9f11192ec13b8f43d5a5a4d55db3ecef4e0cfae4e1f36  missing.tar" > "$test_sha3"
run_test "missing tar file" "$test_dir/missing.tar" "$test_sha3" 0 1

# Test 4: Missing sha256 file should fail
echo "Test 4: Missing sha256 file..."
test_tar4="$test_dir/test4.tar"
echo -n "$test_content" > "$test_tar4"
run_test "missing sha256 file" "$test_tar4" "$test_dir/missing.sha256" 0 1

# Test 5: Empty sha256 file should fail
echo "Test 5: Empty sha256 file..."
test_tar5="$test_dir/test5.tar"
test_sha5="$test_dir/test5.sha256"
echo -n "$test_content" > "$test_tar5"
touch "$test_sha5"  # Empty file
run_test "empty sha256 file" "$test_tar5" "$test_sha5" 0 1

# Tag tests: N comes from the tar name plane-fork-live.<N>.tar or the third argument.
tag_tar="$test_dir/plane-fork-live.1.tar"
tag_sha="$test_dir/plane-fork-live.1.sha256"
echo -n "$test_content" > "$tag_tar"
(cd "$test_dir" && sha256sum plane-fork-live.1.tar > plane-fork-live.1.sha256)
web1="localhost/plane-fork-web:v1.4.2-live.1"
live1="localhost/plane-fork-live:v1.4.2-live.1"

echo "Test 6: all three tags, N derived from the tar name..."
run_test "N from tar name" "$tag_tar" "$tag_sha" 1

echo "Test 7: N from the third argument..."
cp "$tag_tar" "$test_dir/other.tar"
run_test "N from argument" "$test_dir/other.tar" "$tag_sha" 1 1

echo "Test 8: one image missing..."
FAKE_PODMAN_IMAGES="$web1
$live1" run_test "missing api image" "$tag_tar" "$tag_sha" 0

echo "Test 9: one image has the wrong tag..."
FAKE_PODMAN_IMAGES="$web1
$live1
localhost/plane-fork-api:v1.4.2-live.2" run_test "wrong api tag" "$tag_tar" "$tag_sha" 0

echo "Test 10: images from an older build only..."
FAKE_PODMAN_IMAGES="localhost/plane-fork-web:v1.4.2-live.0
localhost/plane-fork-live:v1.4.2-live.0
localhost/plane-fork-api:v1.4.2-live.0" run_test "stale build" "$tag_tar" "$tag_sha" 0

echo "Test 11: N unknown (tar name has no N, no argument)..."
run_test "N unknown" "$test_tar1" "$test_sha1" 0

echo "Test 12: sha256 field is not 64 hex characters..."
echo "abc123  plane-fork-live.1.tar" > "$test_dir/short.sha256"
run_test "short digest" "$tag_tar" "$test_dir/short.sha256" 0

# Docker engine: a fake docker whose `image inspect REF` succeeds only for a line
# of $FAKE_DOCKER_IMAGES. `image exists` is not a docker command and must not be used.
docker_fake="$test_dir/docker"
cat > "$docker_fake" << 'EOF2'
#!/bin/bash
list="${FAKE_DOCKER_IMAGES:-localhost/plane-fork-web:v1.4.2-live.1
localhost/plane-fork-live:v1.4.2-live.1
localhost/plane-fork-api:v1.4.2-live.1}"
case "$1 $2" in
  "load -i") exit 0 ;;
  "image inspect") printf '%s\n' "$list" | grep -qxF -- "$3"; exit $? ;;
  *) exit 1 ;;
esac
EOF2
chmod +x "$docker_fake"

echo "Test 13: CONTAINER_ENGINE=docker, all three tags..."
CONTAINER_ENGINE=docker run_test "docker engine" "$tag_tar" "$tag_sha" 1

echo "Test 14: CONTAINER_ENGINE=docker, one image missing..."
CONTAINER_ENGINE=docker FAKE_DOCKER_IMAGES="$web1
$live1" run_test "docker missing api image" "$tag_tar" "$tag_sha" 0

echo "Test 15: CONTAINER_ENGINE=docker ignores what podman has..."
CONTAINER_ENGINE=docker FAKE_DOCKER_IMAGES="$web1" run_test "docker uses docker only" "$tag_tar" "$tag_sha" 0

echo "Test 16: unknown CONTAINER_ENGINE..."
CONTAINER_ENGINE=rkt run_test "unknown engine" "$tag_tar" "$tag_sha" 0

# Autodetect with only docker installed: PATH holds the fake docker and the few
# tools the script needs, but no podman.
only_docker="$test_dir/only-docker"
mkdir -p "$only_docker"
cp "$docker_fake" "$only_docker/docker"
for tool in awk basename sha256sum tr grep; do
  ln -s "$(command -v $tool)" "$only_docker/$tool"
done
echo "Test 17: autodetect falls back to docker when podman is absent..."
if PATH="$only_docker" "$BASH" "$verify_load" "$tag_tar" "$tag_sha" > /dev/null 2>&1; then
  ((test_count++)); ((pass_count++)); echo -e "${GREEN}PASS${NC} docker autodetect"
else
  ((test_count++)); ((fail_count++)); echo -e "${RED}FAIL${NC} docker autodetect"
fi

echo "Test 18: autodetect prefers podman when both are installed..."
docker_marker="$test_dir/docker-was-called"
cat > "$test_dir/docker" << EOF2
#!/bin/bash
touch "$docker_marker"
exit 1
EOF2
run_test "podman preferred" "$tag_tar" "$tag_sha" 1
((test_count++))
if [ ! -e "$docker_marker" ]; then ((pass_count++)); echo -e "${GREEN}PASS${NC} docker not invoked"; else ((fail_count++)); echo -e "${RED}FAIL${NC} docker invoked"; fi

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
