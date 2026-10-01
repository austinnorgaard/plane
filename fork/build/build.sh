#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# build.sh - build the fork images v1.4.2-live.N on a Linux host and save them
# to a docker-archive tar. Linux counterpart of build.ps1, same contract.
#
# Usage:
#   build.sh --sha <40-hex> --n <int> [--out-dir DIR] [--engine docker|podman]
#                [--ca-bundle FILE] [--build-proxy|--no-build-proxy] [--dry-run]
#
#   --sha      full commit sha to build; must be contained in
#              origin/live-updates/v1.4.2 (checked after a fetch). Required.
#   --n        build number; images are tagged v1.4.2-live.<N>. Required.
#   --out-dir  where plane-fork-live.<N>.tar and .sha256 are written.
#              Default /root/out.
#   --engine   docker or podman. Default: podman if installed, else docker.
#   --ca-bundle FILE
#              PEM bundle of a TLS-intercepting proxy CA. Default: env
#              BUILD_CA_BUNDLE. When set, the copies of apps/web/Dockerfile.web
#              and apps/live/Dockerfile.live inside the temporary build tree
#              (never the ones in the repo) are patched so every RUN
#              mounts the file as a build secret over
#              /etc/ssl/certs/ca-certificates.crt and runs with
#              NODE_EXTRA_CA_CERTS and SSL_CERT_FILE pointing at it (set in
#              the RUN's own shell, no ENV), and the build gets
#              --secret id=build_ca,src=FILE. The file must be a full CA bundle
#              (system roots plus the proxy CA), because it replaces the store
#              during the build step. The CA exists only while those RUN steps
#              execute and is not written to any layer.
#   --build-proxy
#              for hosts whose build containers can only reach the network
#              through a proxy on the host's loopback: build web and live with
#              --network host and pass HTTPS_PROXY/NO_PROXY (and lowercase
#              variants from this shell's environment) as build args. Those are
#              predefined proxy args, so they are not stored in the image config.
#              Auto-enabled when HTTPS_PROXY or https_proxy points to a loopback
#              address (127.0.0.1, localhost, [::1], or 127.0.0.0/8).
#   --no-build-proxy
#              explicitly disable build proxy, overriding auto-detection.
#   --dry-run  print the commands instead of running them (nothing is executed,
#              no fetch, no README change).
#
# Environment:
#   PLANE_BUILD_ROOT  parent of the per-sha build directory and of the MEASURE
#                     sample logs. Default /root/plane-build.
#
# Load the result with fork/build/verify-load.sh.

set -u
set -o pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  sed -n '4,44p' "$0" | sed 's/^# \{0,1\}//' >&2
}

# Check if a proxy URL (scheme://[userinfo@]host[:port][/path?query#fragment]) has a loopback host.
# Returns 0 if it's a loopback (127.0.0.0/8, localhost, ::1), 1 otherwise.
is_loopback_proxy() {
  local url="$1"
  local host
  local lower_host
  # Remove scheme
  url="${url#*://}"
  # Remove path, query, fragment (/, ?, #) BEFORE stripping userinfo
  url="${url%%[/?#]*}"
  # Remove optional userinfo (everything before @)
  url="${url##*@}"
  # Remove optional port (everything after : or [)
  if [[ "$url" =~ ^\[.*\] ]]; then
    host="${url%%\]*}"
    host="${host#\[}"
  else
    host="${url%%:*}"
  fi

  # Check if host is a loopback address
  # IPv6 loopback: ::1
  if [[ "$host" == "::1" ]]; then
    return 0
  fi

  # Hostname loopback (case-insensitive): localhost
  lower_host="${host,,}"  # bash 4+: convert to lowercase
  if [[ "$lower_host" == "localhost" ]]; then
    return 0
  fi

  # IPv4 loopback: strict match for 127.x.y.z where x,y,z are 0-255 (base-10)
  if [[ "$host" =~ ^127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    # Validate each octet is 0-255 using base-10 comparison
    local o2=$((10#${BASH_REMATCH[1]})) o3=$((10#${BASH_REMATCH[2]})) o4=$((10#${BASH_REMATCH[3]}))
    (( o2 <= 255 && o3 <= 255 && o4 <= 255 )) && return 0
  fi

  return 1
}

sha=""
n=""
out_dir="/root/out"
engine=""
dry_run=0
ca_bundle="${BUILD_CA_BUNDLE:-}"
build_proxy=""  # "" = auto, "1" = enabled, "0" = disabled
build_proxy_explicit=""  # Track which flag was given to detect conflicts

while [ $# -gt 0 ]; do
  case "$1" in
    --sha|--n|--out-dir|--engine|--ca-bundle)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --sha) sha="$2" ;;
        --n) n="$2" ;;
        --out-dir) out_dir="$2" ;;
        --engine) engine="$2" ;;
        --ca-bundle) ca_bundle="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=1; shift ;;
    --build-proxy)
      [ -z "$build_proxy_explicit" ] || die "cannot use both --build-proxy and --no-build-proxy"
      build_proxy=1
      build_proxy_explicit=--build-proxy
      shift
      ;;
    --no-build-proxy)
      [ -z "$build_proxy_explicit" ] || die "cannot use both --build-proxy and --no-build-proxy"
      build_proxy=0
      build_proxy_explicit=--no-build-proxy
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

[ -n "$sha" ] || { usage; die "--sha is required"; }
[ -n "$n" ] || { usage; die "--n is required"; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "Invalid SHA format: must be 40 hex characters, got '$sha'"
[[ "$n" =~ ^[0-9]+$ ]] || die "N must be a non-negative integer, got '$n'"
n=$((10#$n)) # 007 and 7 are the same build; also avoids octal parsing
out_dir="${out_dir%/}"
[[ "$out_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Invalid --out-dir: must be an absolute path, got '$out_dir'"

# Auto-detect build proxy if not explicitly set.
if [ -z "$build_proxy" ]; then
  proxy_url="${HTTPS_PROXY:-${https_proxy:-}}"
  if [ -n "$proxy_url" ] && is_loopback_proxy "$proxy_url"; then
    build_proxy=1
    [ "$dry_run" -eq 0 ] && echo "Auto-enabling build proxy for loopback HTTPS_PROXY"
  else
    build_proxy=0
  fi
fi

if [ -n "$ca_bundle" ]; then
  [[ "$ca_bundle" =~ ^[A-Za-z0-9._/@+-]+$ ]] || die "Invalid --ca-bundle path '$ca_bundle'"
  if [ "$dry_run" -eq 0 ]; then
    [ -f "$ca_bundle" ] && [ -r "$ca_bundle" ] || die "--ca-bundle '$ca_bundle' is not a readable file"
    grep -q -- '-----BEGIN CERTIFICATE-----' "$ca_bundle" || die "--ca-bundle '$ca_bundle' contains no PEM certificate"
    ca_bundle="$(cd "$(dirname "$ca_bundle")" && pwd)/$(basename "$ca_bundle")"
  fi
fi

if [ -n "$engine" ]; then
  case "$engine" in
    docker|podman) ;;
    *) die "Invalid --engine '$engine': must be docker or podman" ;;
  esac
  command -v "$engine" >/dev/null 2>&1 || [ "$dry_run" -eq 1 ] || die "engine '$engine' not found on PATH"
else
  if command -v podman >/dev/null 2>&1; then
    engine=podman
  elif command -v docker >/dev/null 2>&1; then
    engine=docker
  elif [ "$dry_run" -eq 1 ]; then
    engine='<engine>'
  else
    die "neither podman nor docker found on PATH"
  fi
fi

image_tag="v1.4.2-live.$n"
tar_name="plane-fork-live.$n.tar"
sha256_name="plane-fork-live.$n.sha256"
build_root="${PLANE_BUILD_ROOT:-/root/plane-build}"
build_root="${build_root%/}"
build_dir="$build_root/$sha"
build_label="plane-fork-build=$sha"
branch="live-updates/v1.4.2"

# The checkout that holds this script, not the caller's working directory.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Run a command, or only print it in dry-run mode.
run() {
  if [ "$dry_run" -eq 1 ]; then
    printf '%s' "+"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# 1. Sha gate.
if [ "$dry_run" -eq 1 ]; then
  echo "+ git -C <repo> fetch origin $branch --quiet"
  echo "+ git -C <repo> merge-base --is-ancestor $sha origin/$branch"
else
  echo "Verifying SHA $sha is in origin/$branch..."
  git -C "$repo_root" fetch origin "$branch" --quiet || die "Failed to fetch origin/$branch"
  git -C "$repo_root" merge-base --is-ancestor "$sha" "origin/$branch" ||
    die "SHA $sha is not contained in origin/$branch. Refusing to build."
  echo "SHA verified: $sha is in origin/$branch"
fi

# 2. Fresh build dir with the source tree of the sha.
if [ "$dry_run" -eq 1 ]; then
  echo "+ rm -rf $build_dir && mkdir -p $build_dir"
  echo "+ git -C <repo> -c core.autocrlf=false archive --format=tar $sha | tar -x --no-same-owner -C $build_dir"
  echo "extracted file count is compared with: git ls-tree -r $sha (minus submodule entries)"
else
  echo "Archiving $sha into $build_dir..."
  rm -rf "$build_dir" || die "Cannot remove old $build_dir"
  mkdir -p "$build_dir" || die "Cannot prepare $build_dir"
  git -C "$repo_root" -c core.autocrlf=false archive --format=tar "$sha" |
    tar -x --no-same-owner -C "$build_dir" || die "git archive or extraction failed"

  # Loud failure for a damaged or partial extract: compare the number of files
  # with the number of blobs in the commit (submodule entries are not archived).
  tree="$(git -C "$repo_root" ls-tree -r "$sha")" || die "git ls-tree failed"
  expected_files="$(printf '%s\n' "$tree" | awk 'NF && $1 != "160000"' | wc -l | tr -d ' ')"
  actual_files="$(cd "$build_dir" && find . \( -type f -o -type l \) | wc -l | tr -d ' ')"
  [ "$actual_files" = "$expected_files" ] ||
    die "Extraction check failed: $actual_files files in $build_dir, $expected_files in commit $sha"
  echo "Extraction verified: $actual_files files"
fi

# 2b. With --ca-bundle: patch the build tree's copies of the two Dockerfiles that
# need the CA (apk uses the system store, node uses NODE_EXTRA_CA_CERTS).
patch_dockerfile() { # patch_dockerfile FILE (a path in the build tree)
  local f="$1" ca=/etc/ssl/certs/ca-certificates.crt
  # Shell-form, single-line RUN only; anything else cannot be prefixed safely.
  if grep -Eq '^RUN( --[^ ]+)* \[' "$f" || grep -Eq '^RUN .*\\$' "$f" || grep -Eq '^RUN .*<<' "$f"; then
    echo "ERROR: $f has an exec-form, multi-line or heredoc RUN; cannot patch" >&2
    return 1
  fi
  # RUN [flags] cmd  ->  RUN --mount=<secret> [flags] export CA vars; cmd
  # The variables are set inside that one RUN's shell, not with ENV or ARG.
  sed -i -E "s#^RUN ((--[^ ]+ )*)#RUN --mount=type=secret,id=build_ca,target=$ca \\1export NODE_EXTRA_CA_CERTS=$ca SSL_CERT_FILE=$ca; #" "$f" ||
    return 1
  head -n1 "$f" | grep -q '^# syntax=' || sed -i '1i # syntax=docker/dockerfile:1' "$f" || return 1
  [ "$(grep -c '^RUN ' "$f")" -eq "$(grep -c '^RUN --mount=type=secret,id=build_ca,' "$f")" ] || return 1
}
if [ -n "$ca_bundle" ]; then
  if [ "$dry_run" -eq 1 ]; then
    echo "+ patch every RUN line of $build_dir/apps/web/Dockerfile.web and $build_dir/apps/live/Dockerfile.live (build tree copies only) to mount secret build_ca"
  else
    for f in apps/web/Dockerfile.web apps/live/Dockerfile.live; do
      patch_dockerfile "$build_dir/$f" || die "Patching $f for --ca-bundle failed"
    done
    echo "Patched every RUN of the web and live Dockerfiles in the build tree to use secret build_ca"
  fi
fi

# 3. Build the three images through measure.sh. --label marks the images so the
# prune below only touches this build's leftovers. The CPU cap that build.ps1
# uses to keep a shared PC responsive is applied for podman only; a cloud host
# is not shared and docker build does not take these flags with BuildKit.
cpu_flags=()
[ "$engine" = podman ] && cpu_flags=(--cpu-period=100000 --cpu-quota=800000)

measure_dir="$build_root/logs"
measure_out=""
if [ "$dry_run" -eq 0 ]; then
  measure_out="$(mktemp)" || die "mktemp failed"
  trap 'rm -f "$measure_out"' EXIT
fi
run mkdir -p "$measure_dir" || die "Cannot create $measure_dir"

echo "Building images with tag $image_tag..."
declare -A dockerfile=(
  [web]=apps/web/Dockerfile.web
  [live]=apps/live/Dockerfile.live
  [api]=fork/docker/Dockerfile.fork-api
)
builds=(web live api)
for b in "${builds[@]}"; do
  flags=()
  [ "$b" = api ] || flags=(${cpu_flags[@]+"${cpu_flags[@]}"})
  if [ "$b" != api ]; then
    [ -z "$ca_bundle" ] || flags+=(--secret "id=build_ca,src=$ca_bundle")
    if [ "$build_proxy" -eq 1 ]; then
      flags+=(--network host --build-arg HTTPS_PROXY --build-arg https_proxy --build-arg NO_PROXY --build-arg no_proxy)
    fi
  fi
  cmd=(fork/test/measure.sh "$b" "$engine" build ${flags[@]+"${flags[@]}"} --label "$build_label"
    -f "${dockerfile[$b]}" -t "localhost/plane-fork-$b:$image_tag" .)
  if [ "$dry_run" -eq 1 ]; then
    printf '+ (cd %s && MEASURE_DIR=%s' "$build_dir" "$measure_dir"
    printf ' %q' "${cmd[@]}"
    printf ')\n'
  else
    (cd "$build_dir" && MEASURE_DIR="$measure_dir" "${cmd[@]}") 2>&1 | tee -a "$measure_out"
    rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || die "Build of $b failed (exit code $rc)"
  fi
done

# 4. Save as docker-archive and checksum.
refs=("localhost/plane-fork-web:$image_tag" "localhost/plane-fork-live:$image_tag" "localhost/plane-fork-api:$image_tag")
echo "Saving images to $out_dir/$tar_name..."
run mkdir -p "$out_dir" || die "Cannot create $out_dir"
if [ "$engine" = podman ]; then
  run podman save -m --format docker-archive -o "$out_dir/$tar_name" "${refs[@]}" || die "Saving images failed"
else
  run "$engine" save -o "$out_dir/$tar_name" "${refs[@]}" || die "Saving images failed"
fi
echo "Creating sha256 checksum..."
if [ "$dry_run" -eq 1 ]; then
  echo "+ (cd $out_dir && sha256sum $tar_name > $sha256_name)"
else
  (cd "$out_dir" && sha256sum "$tar_name" > "$sha256_name") || die "Creating the checksum failed"
fi

# 5. Label-scoped prune: only dangling (untagged) images that carry this build's
# label. Base images, other builds' images and cache mounts are not touched.
echo "Pruning this build's dangling images ($build_label)..."
pruned_count=0
if [ "$dry_run" -eq 1 ]; then
  echo "+ $engine image prune -f --filter dangling=true --filter label=$build_label"
else
  if pruned="$("$engine" image prune -f --filter dangling=true --filter label="$build_label")"; then
    pruned_count="$(printf '%s\n' "$pruned" | grep -cE '^(deleted: |[0-9a-f]{64}$)' || true)"
  else
    echo "WARNING: prune failed, continuing" >&2
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  echo "+ $engine images --filter reference=localhost/plane-fork-*:$image_tag (must list exactly the three tags)"
  echo "+ append the build block to $repo_root/fork/README.md"
  exit 0
fi

# 6. Exactly the three expected images must exist.
echo "Verifying images were created..."
expected="$(printf '%s\n' "${refs[@]}" | sort)"
listed="$("$engine" images --filter "reference=localhost/plane-fork-*:$image_tag" --format '{{.Repository}}:{{.Tag}}' | sort)" ||
  die "Listing images failed"
[ "$listed" = "$expected" ] || die "Expected images $(tr "\n" " " <<<"$expected") but found: $(tr "\n" " " <<<"$listed")"
echo "Images verified: $(tr "\n" " " <<<"$listed")"

tar_sha="$(awk '{print $1; exit}' "$out_dir/$sha256_name")"
[[ "$tar_sha" =~ ^[0-9a-f]{64}$ ]] || die "Unexpected checksum file content"
echo "Tar sha256: $tar_sha"

# 7. Append the results to fork/README.md (LF line endings).
echo "Updating fork/README.md with results..."
readme="$repo_root/fork/README.md"
block="### Build $n - $(date -u '+%Y-%m-%d %H:%M:%S') UTC
- SHA: $sha
- Output: $tar_name, sha256 $tar_sha ($sha256_name)
- Tags: $(printf '%s\n' "${refs[@]}" | sort | paste -sd, - | sed 's/,/, /g')
"
for b in "${builds[@]}"; do
  line="$(grep -E "^MEASURE label=$b " "$measure_out" | tail -1)"
  [ -n "$line" ] || die "No MEASURE line captured for the $b build"
  get() { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
  block+="- $b build: $(get wall_s) s wall, peak RAM used $(get peak_used_mb) MB (+$(get peak_delta_mb) MB over idle), lowest available $(get min_available_mb) MB
"
done
block+="- Prune ($build_label, dangling only): $pruned_count image(s) removed
"

if [ ! -f "$readme" ]; then
  printf '# Plane Fork Build Results\n\nBuild results for plane-fork images v1.4.2-live releases.\n\n## Builds\n\n' > "$readme"
elif [ -n "$(tail -c1 "$readme")" ]; then
  printf '\n' >> "$readme"
fi
printf '%s\n' "$block" >> "$readme"
echo "Results appended to fork/README.md"
echo "Build complete!"
