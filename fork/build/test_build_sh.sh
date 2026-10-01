#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# test_build_sh.sh - test build.sh with stubbed git, docker and podman.
#
# build.sh is copied into a throw-away repo skeleton together with the real
# fork/test/measure.sh, so the README it appends to and the MEASURE lines it
# captures are the real thing, and nothing in the working tree is touched.
# The stubs log every call to $CALLS.
#
# Exit 0 if all tests pass; exit 1 if any test fails.

# shellcheck disable=SC2319  # '[ ... ]; check NAME $?' reads the exit code of the test on purpose
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_src="${BUILD_SH:-$script_dir/build.sh}"
measure_src="$script_dir/../test/measure.sh"

pass=0
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { # check NAME CONDITION-EXIT-CODE
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

SHA=0123456789abcdef0123456789abcdef01234567

# --- fixture: the "commit" (a small tree with one symlink) -------------------
tree="$work/tree"
mkdir -p "$tree/apps/web" "$tree/apps/live" "$tree/fork/test"
printf '%s\n' '# syntax=docker/dockerfile:1.7' 'FROM node:22-alpine' 'RUN apk add --no-cache libc6-compat' \
  'RUN corepack enable' 'RUN apk update && apk upgrade --no-cache' 'RUN echo "capkx"' > "$tree/apps/web/Dockerfile.web"
printf '%s\n' 'FROM node:22-alpine' 'RUN apk update' 'RUN --mount=type=cache,id=x,target=/x apk add foo' 'COPY apk /apk' > "$tree/apps/live/Dockerfile.live"
cp "$tree/apps/web/Dockerfile.web" "$work/web.orig"; cp "$tree/apps/live/Dockerfile.live" "$work/live.orig"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'AAAA' '-----END CERTIFICATE-----' > "$work/ca.pem"
echo a > "$tree/a.txt"
echo b > "$tree/b.txt"
ln -s a.txt "$tree/link"
cp "$measure_src" "$tree/fork/test/measure.sh"
chmod +x "$tree/fork/test/measure.sh"
tree_files=$(cd "$tree" && find . \( -type f -o -type l \) | wc -l | tr -d ' ')

# --- stubs -------------------------------------------------------------------
stubs="$work/stubs"
mkdir -p "$stubs"
cat > "$stubs/git" << 'EOF2'
#!/bin/bash
echo "git $*" >> "$CALLS"
while [ $# -gt 0 ]; do
  case "$1" in
    -C) shift 2 ;;
    -c) shift 2 ;;
    *) break ;;
  esac
done
cmd="$1"; shift
case "$cmd" in
  fetch) exit "${GIT_FETCH_RC:-0}" ;;
  merge-base) exit "${GIT_ANCESTOR_RC:-0}" ;;
  archive) tar -c -C "$FIXTURE_TREE" . ; exit 0 ;;
  ls-tree)
    (cd "$FIXTURE_TREE" && find . \( -type f -o -type l \) | sed 's|^\./||' | while read -r f; do
      printf '100644 blob deadbeef\t%s\n' "$f"
    done)
    for i in $(seq 1 "${GIT_LSTREE_EXTRA:-0}"); do printf '100644 blob deadbeef\textra%s\n' "$i"; done
    if [ "${GIT_LSTREE_SUBMODULE:-0}" = 1 ]; then printf '160000 commit deadbeef\tvendor/sub\n'; fi
    exit 0 ;;
esac
exit 1
EOF2
for e in docker podman; do
  cat > "$stubs/$e" << EOF2
#!/bin/bash
echo "$e \$*" >> "\$CALLS"
case "\$1" in
  build)
    case " \$* " in *" -t localhost/plane-fork-\${FAKE_FAIL_BUILD:-none}:"*) echo "build error" >&2; exit 3 ;; esac
    sleep 0.3; echo "built"
    exit 0 ;;
  save)
    out=""
    while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
    echo "tar-bytes-$e" > "\$out"
    exit 0 ;;
  image)
    if [ "\$2" = prune ]; then
      echo "Deleted Images:"; echo "deleted: sha256:aaa"; echo "deleted: sha256:bbb"
      exit \${FAKE_PRUNE_RC:-0}
    fi
    exit 1 ;;
  images)
    if [ -n "\${FAKE_IMAGES:-}" ]; then printf '%s\n' "\$FAKE_IMAGES"; exit 0; fi
    tag=\${FAKE_TAG:-v1.4.2-live.1}
    for n in web live api; do echo "localhost/plane-fork-\$n:\$tag"; done
    exit 0 ;;
esac
exit 1
EOF2
  chmod +x "$stubs/$e"
done
chmod +x "$stubs/git"

# --- one run in a fresh skeleton ---------------------------------------------
# run_build ARGS... : sets $rc, $out (stdout+stderr), $repo, $CALLS
run_build() {
  local id
  id=$((${id_counter:-0} + 1)); id_counter=$id
  repo="$work/repo$id"
  mkdir -p "$repo/fork/build" "$repo/fork/test"
  cp "$build_src" "$repo/fork/build/build.sh"
  chmod +x "$repo/fork/build/build.sh"
  printf '# Plane Fork Build Results\n\n## Builds\n\n' > "$repo/fork/README.md"
  cp "$repo/fork/README.md" "$repo/README.before"
  CALLS="$repo/calls.log"; : > "$CALLS"
  export CALLS FIXTURE_TREE="$tree"
  export PLANE_BUILD_ROOT="$repo/work"
  out="$(PATH="$stubs:$PATH" "$repo/fork/build/build.sh" "$@" 2>&1)"
  rc=$?
}
readme_unchanged() { cmp -s "$repo/fork/README.md" "$repo/README.before"; }
calls_of() { grep -c "^$1 " "$CALLS"; }

# Clear proxy environment for tests that explicitly control it
unset HTTPS_PROXY https_proxy

# 1. sha gate refusal
GIT_ANCESTOR_RC=1 run_build --sha $SHA --n 1 --out-dir "$work/out1" --engine docker
[ $rc -ne 0 ]; check "sha gate: non-zero exit" $?
echo "$out" | grep -q "Refusing to build"; check "sha gate: says it refuses" $?
[ "$(calls_of docker)" -eq 0 ]; check "sha gate: engine never called" $?
grep -q "^git .*fetch origin live-updates/v1.4.2" "$CALLS"; check "sha gate: fetched first" $?
grep -q "merge-base --is-ancestor $SHA origin/live-updates/v1.4.2" "$CALLS"; check "sha gate: merge-base against origin branch" $?
[ ! -e "$repo/work/$SHA" ]; check "sha gate: no build dir created" $?
readme_unchanged; check "sha gate: README untouched" $?

GIT_FETCH_RC=1 run_build --sha $SHA --n 1 --out-dir "$work/out1b" --engine docker
[ $rc -ne 0 ] && [ "$(calls_of docker)" -eq 0 ]; check "fetch failure: refuses to build" $?

# 2. dry run executes nothing
run_build --sha $SHA --n 2 --out-dir "$work/out2" --engine docker --dry-run
[ $rc -eq 0 ]; check "dry-run: exit 0" $?
[ ! -s "$CALLS" ]; check "dry-run: no git, docker or podman call" $?
[ ! -e "$repo/work" ] && [ ! -e "$work/out2" ]; check "dry-run: no directories created" $?
# no mktemp in dry-run: a stub mktemp that logs, and TMPDIR left empty
mkdir -p "$work/stubs2"; printf '#!/bin/bash\necho mktemp >> "$CALLS"\nexit 1\n' > "$work/stubs2/mktemp"; chmod +x "$work/stubs2/mktemp"
stubs_save="$stubs"; stubs="$work/stubs2:$stubs"
run_build --sha $SHA --n 2 --out-dir "$work/out2" --engine docker --dry-run
[ $rc -eq 0 ] && ! grep -q '^mktemp' "$CALLS"; check "dry-run: mktemp is not called" $?
stubs="$stubs_save"
readme_unchanged; check "dry-run: README untouched" $?
[ "$(echo "$out" | grep -c 'measure.sh')" -eq 3 ]; check "dry-run: prints the three measured builds" $?
echo "$out" | grep -q "plane-fork-build=$SHA" && echo "$out" | grep -q 'v1.4.2-live.2'; check "dry-run: label and tag shown" $?
echo "$out" | grep -q -- 'docker save -o '; check "dry-run: docker save command shown" $?

# 2b. --ca-bundle in dry-run prints the patch and the secret, touches nothing
run_build --sha $SHA --n 2 --out-dir "$work/out2c" --engine docker --ca-bundle "$work/ca.pem" --dry-run
[ $rc -eq 0 ] && echo "$out" | grep -q 'patch every RUN line' && [ "$(echo "$out" | grep -c -- "--secret id=build_ca..\?src=$work/ca.pem")" -eq 2 ]; check "dry-run --ca-bundle: patch and two --secret shown" $?
[ ! -s "$CALLS" ] && [ ! -e "$repo/work" ]; check "dry-run --ca-bundle: nothing executed or created" $?
run_build --sha $SHA --n 2 --out-dir "$work/out2d" --engine docker --dry-run
! echo "$out" | grep -q -e 'build_ca' -e 'patch every'; check "dry-run without --ca-bundle: no patch, no secret" $?

# 3. build failure gives a non-zero exit
FAKE_FAIL_BUILD=live run_build --sha $SHA --n 3 --out-dir "$work/out3" --engine docker
[ $rc -ne 0 ]; check "build failure: non-zero exit" $?
echo "$out" | grep -q "Build of live failed"; check "build failure: names the failed build" $?
[ "$(calls_of docker)" -eq 2 ] && ! grep -q 'plane-fork-api' "$CALLS"; check "build failure: api build not started" $?
[ ! -e "$work/out3/plane-fork-live.3.tar" ]; check "build failure: no tar written" $?
readme_unchanged; check "build failure: README untouched" $?

FAKE_FAIL_BUILD=api run_build --sha $SHA --n 3 --out-dir "$work/out3b" --engine podman
[ $rc -ne 0 ] && [ ! -e "$work/out3b/plane-fork-live.3.tar" ] && readme_unchanged; check "build failure (api, podman): non-zero, nothing published" $?

# 4. success with docker: MEASURE lines end up in the README block
run_build --sha $SHA --n 1 --out-dir "$work/out4" --engine docker
[ $rc -eq 0 ]; check "success (docker): exit 0" $?
[ "$(grep -c '^docker build ' "$CALLS")" -eq 3 ]; check "success (docker): three builds" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- "--label plane-fork-build=$SHA")" -eq 3 ]; check "success (docker): every build labelled" $?
grep -q '^docker build .* -f apps/web/Dockerfile.web -t localhost/plane-fork-web:v1.4.2-live.1 \.$' "$CALLS" &&
  grep -q -- '-f apps/live/Dockerfile.live -t localhost/plane-fork-live:v1.4.2-live.1 \.$' "$CALLS" &&
  grep -q -- '-f fork/docker/Dockerfile.fork-api -t localhost/plane-fork-api:v1.4.2-live.1 \.$' "$CALLS"; check "success (docker): dockerfiles and tags" $?
! grep '^docker build ' "$CALLS" | grep -q -- '--build-arg'; check "success (docker): no build args" $?
! grep '^docker build ' "$CALLS" | grep -q -- '--cpu-'; check "success (docker): no cpu cap flags" $?
grep -q '^docker save -o .*plane-fork-live.1.tar localhost/plane-fork-web:v1.4.2-live.1 localhost/plane-fork-live:v1.4.2-live.1 localhost/plane-fork-api:v1.4.2-live.1$' "$CALLS"; check "success (docker): docker save with the three tags" $?
grep -q '^docker image prune -f --filter dangling=true --filter label=plane-fork-build='"$SHA"'$' "$CALLS"; check "success (docker): label-scoped dangling prune" $?
[ "$(cd "$work/out4" && sha256sum -c plane-fork-live.1.sha256 2>&1 | grep -c ': OK$')" -eq 1 ]; check "success (docker): sha256 file verifies the tar" $?
[ "$(wc -l < "$work/out4/plane-fork-live.1.sha256")" -eq 1 ] && grep -q '^[0-9a-f]\{64\}  plane-fork-live.1.tar$' "$work/out4/plane-fork-live.1.sha256"; check "success (docker): sha256 file format" $?
[ -f "$repo/work/$SHA/a.txt" ] && [ -L "$repo/work/$SHA/link" ]; check "success (docker): tree extracted, symlink kept" $?
echo "$out" | grep -q "Extraction verified: $tree_files files"; check "success (docker): extraction count checked" $?
readme="$repo/fork/README.md"
tar_sha="$(sha256sum "$work/out4/plane-fork-live.1.tar" | cut -d' ' -f1)"
grep -q '^### Build 1 - [0-9-]* [0-9:]* UTC$' "$readme"; check "README: block header" $?
grep -q "^- SHA: $SHA\$" "$readme"; check "README: sha line" $?
grep -q "^- Output: plane-fork-live.1.tar, sha256 $tar_sha (plane-fork-live.1.sha256)\$" "$readme"; check "README: output line" $?
grep -q '^- Tags: localhost/plane-fork-api:v1.4.2-live.1, localhost/plane-fork-live:v1.4.2-live.1, localhost/plane-fork-web:v1.4.2-live.1$' "$readme"; check "README: tags line" $?
for b in web live api; do
  grep -Eq "^- $b build: [0-9]+ s wall, peak RAM used [0-9]+ MB \(\+-?[0-9]+ MB over idle\), lowest available [0-9]+ MB\$" "$readme"; check "README: MEASURE captured for $b" $?
done
# The number in the README is the number measure.sh printed for that build.
for b in web live api; do
  meas="$(echo "$out" | grep "^MEASURE label=$b " | sed -n 's/.* peak_used_mb=\([0-9]*\) .*/\1/p')"
  [ -n "$meas" ] && grep -q "^- $b build: .* peak RAM used $meas MB" "$readme"; check "README: $b peak RAM equals the MEASURE line" $?
done
grep -q "^- Prune (plane-fork-build=$SHA, dangling only): 2 image(s) removed\$" "$readme"; check "README: prune count" $?
! grep -q "$work" "$readme" && ! grep -q '/root' "$readme"; check "README: no host paths" $?
[ -z "$(tail -c1 "$readme")" ]; check "README: ends with a newline" $?
[ "$(grep -c '^### Build' "$readme")" -eq 1 ]; check "README: one block" $?
[ -f "$repo/work/logs/web.free.log" ]; check "MEASURE sample logs go under the build root" $?

# Second build appends, does not overwrite.
cp "$repo/fork/README.md" "$work/readme.keep"
(
  export PLANE_BUILD_ROOT="$repo/work" CALLS FIXTURE_TREE="$tree"
  PATH="$stubs:$PATH" "$repo/fork/build/build.sh" --sha $SHA --n 1 --out-dir "$work/out4" --engine docker > /dev/null 2>&1
)
[ "$(grep -c '^### Build' "$repo/fork/README.md")" -eq 2 ] && head -c "$(wc -c < "$work/readme.keep")" "$repo/fork/README.md" | cmp -s - "$work/readme.keep"; check "README: second build appends" $?

# 4b. --ca-bundle: patched copies in the build tree only, secret passed
run_build --sha $SHA --n 1 --out-dir "$work/out4b" --engine docker --ca-bundle "$work/ca.pem"
bt="$repo/work/$SHA"
[ $rc -eq 0 ]; check "ca-bundle: exit 0" $?
M='RUN --mount=type=secret,id=build_ca,target=/etc/ssl/certs/ca-certificates.crt'
X='export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt; '
[ "$(grep -c "^$M " "$bt/apps/web/Dockerfile.web")" -eq 4 ] && [ "$(grep -c "^RUN " "$bt/apps/web/Dockerfile.web")" -eq 4 ] &&
  [ "$(grep -c "^$M " "$bt/apps/live/Dockerfile.live")" -eq 2 ] && [ "$(grep -c "^RUN " "$bt/apps/live/Dockerfile.live")" -eq 2 ]; check "ca-bundle: every RUN (apk or not) in web and live mounts the secret" $?
grep -q "^$M ${X}apk add --no-cache libc6-compat\$" "$bt/apps/web/Dockerfile.web" && grep -q "^$M ${X}corepack enable\$" "$bt/apps/web/Dockerfile.web" && grep -q "^$M ${X}echo \"capkx\"\$" "$bt/apps/web/Dockerfile.web" && grep -q '^COPY apk /apk$' "$bt/apps/live/Dockerfile.live"; check "ca-bundle: CA env exported inside each RUN, other lines untouched" $?
! grep -Eq '^(ENV|ARG) .*(NODE_EXTRA_CA_CERTS|SSL_CERT_FILE)' "$bt/apps/web/Dockerfile.web" "$bt/apps/live/Dockerfile.live"; check "ca-bundle: no ENV or ARG for the CA" $?
grep -q "^$M --mount=type=cache,id=x,target=/x ${X}apk add foo\$" "$bt/apps/live/Dockerfile.live"; check "ca-bundle: existing RUN flags kept before the export" $?
[ "$(head -n1 "$bt/apps/web/Dockerfile.web")" = '# syntax=docker/dockerfile:1.7' ] && [ "$(head -n1 "$bt/apps/live/Dockerfile.live")" = '# syntax=docker/dockerfile:1' ]; check "ca-bundle: syntax line kept or added" $?
cmp -s "$tree/apps/web/Dockerfile.web" "$work/web.orig" && cmp -s "$tree/apps/live/Dockerfile.live" "$work/live.orig"; check "ca-bundle: source Dockerfiles in the repo tree untouched" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- "--secret id=build_ca,src=$work/ca.pem")" -eq 2 ] && ! grep '^docker build ' "$CALLS" | grep 'plane-fork-api' | grep -q -- '--secret'; check "ca-bundle: --secret on web and live only" $?
! grep '^docker build ' "$CALLS" | grep -q -e '--network' -e '--build-arg'; check "ca-bundle: no network or build-arg without --build-proxy" $?
! grep -rq 'BEGIN CERTIFICATE' "$repo/fork/README.md" "$bt/apps"; check "ca-bundle: CA content not in README or build tree" $?
# env default, and no patch without the option
BUILD_CA_BUNDLE="$work/ca.pem" run_build --sha $SHA --n 1 --out-dir "$work/out4c" --engine docker
grep -q 'id=build_ca' "$repo/work/$SHA/apps/live/Dockerfile.live" && [ "$(grep -c -- '--secret' "$CALLS")" -eq 2 ]; check "ca-bundle: BUILD_CA_BUNDLE is the default" $?
run_build --sha $SHA --n 1 --out-dir "$work/out4d" --engine docker
! grep -rq 'build_ca' "$repo/work/$SHA/apps" && ! grep -q -- '--secret' "$CALLS" && cmp -s "$repo/work/$SHA/apps/web/Dockerfile.web" "$work/web.orig"; check "no --ca-bundle: nothing patched, no --secret" $?
run_build --sha $SHA --n 1 --out-dir "$work/out4e" --engine docker --ca-bundle "$work/ca.pem" --build-proxy
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY --build-arg https_proxy --build-arg NO_PROXY --build-arg no_proxy')" -eq 2 ]; check "build-proxy: host network, proxy and NO_PROXY build args on web and live" $?
run_build --sha $SHA --n 1 --out-dir "$work/out4f" --engine docker --ca-bundle "$work/missing.pem"
[ $rc -ne 0 ] && [ ! -s "$CALLS" ]; check "ca-bundle: missing file rejected before any work" $?
: > "$work/empty.pem"
run_build --sha $SHA --n 1 --out-dir "$work/out4g" --engine docker --ca-bundle "$work/empty.pem"
[ $rc -ne 0 ] && [ ! -s "$CALLS" ]; check "ca-bundle: file without a certificate rejected" $?

# 4b2. unpatchable RUN forms are refused
printf '%s\n' 'FROM x' 'RUN apk add \\' '  foo' > "$tree/apps/live/Dockerfile.live"
run_build --sha $SHA --n 1 --out-dir "$work/out4m" --engine docker --ca-bundle "$work/ca.pem"
[ $rc -ne 0 ] && echo "$out" | grep -q 'cannot patch' && [ "$(calls_of docker)" -eq 0 ]; check "ca-bundle: multi-line RUN refused before building" $?
cp "$work/live.orig" "$tree/apps/live/Dockerfile.live"

# 4b3. RUN with flags before exec-form is detected and refused
printf '%s\n' 'FROM x' 'RUN --mount=type=cache,id=x,target=/x [ "echo", "test" ]' > "$tree/apps/live/Dockerfile.live"
run_build --sha $SHA --n 1 --out-dir "$work/out4n" --engine docker --ca-bundle "$work/ca.pem"
[ $rc -ne 0 ] && echo "$out" | grep -q 'cannot patch' && [ "$(calls_of docker)" -eq 0 ]; check "ca-bundle: RUN with flags before exec-form refused" $?
cp "$work/live.orig" "$tree/apps/live/Dockerfile.live"

# 4c. n is normalized: 007 is build 7
FAKE_TAG=v1.4.2-live.7 run_build --sha $SHA --n 007 --out-dir "$work/out4h" --engine docker
[ $rc -eq 0 ] && [ -f "$work/out4h/plane-fork-live.7.tar" ] && grep -q '^### Build 7 - ' "$repo/fork/README.md" && grep -q 'plane-fork-web:v1.4.2-live.7 ' "$CALLS"; check "n: 007 normalized to 7 (tag, files, README)" $?
FAKE_TAG=v1.4.2-live.8 run_build --sha $SHA --n 08 --out-dir "$work/out4i" --engine docker
[ $rc -eq 0 ] && [ -f "$work/out4i/plane-fork-live.8.tar" ]; check "n: 08 is not parsed as octal" $?

# 4d. failing mkdir / rm are fatal
mkdir -p "$work/stubs3"
printf '#!/bin/bash\necho "mkdir $*" >> "$CALLS"\nexit 1\n' > "$work/stubs3/mkdir"
printf '#!/bin/bash\necho "rm $*" >> "$CALLS"\nexit 1\n' > "$work/stubs3/rm"
chmod +x "$work/stubs3/mkdir" "$work/stubs3/rm"
stubs_save="$stubs"; stubs="$work/stubs3:$stubs"
run_build --sha $SHA --n 1 --out-dir "$work/out4j" --engine docker
[ $rc -ne 0 ] && echo "$out" | grep -q 'Cannot' && [ "$(calls_of docker)" -eq 0 ]; check "failing rm/mkdir of the build dir: fatal before building" $?
stubs="$stubs_save"
mkdir -p "$work/stubs4"
printf '#!/bin/bash\n[ "$1" = -p ] && case "$2" in */logs) echo "mkdir $*" >> "$CALLS"; exit 1 ;; esac\nexec /bin/mkdir "$@"\n' > "$work/stubs4/mkdir"
printf '#!/bin/bash\n[ "$1" = -p ] && case "$2" in *out4k*) echo "mkdir $*" >> "$CALLS"; exit 1 ;; esac\nexec /bin/mkdir "$@"\n' > "$work/stubs4/mkdir2"
chmod +x "$work/stubs4/mkdir" "$work/stubs4/mkdir2"
stubs="$work/stubs4:$stubs"
run_build --sha $SHA --n 1 --out-dir "$work/out4k" --engine docker
[ $rc -ne 0 ] && echo "$out" | grep -q 'Cannot create' && [ "$(calls_of docker)" -eq 0 ]; check "failing mkdir of the logs dir: fatal before building" $?
rm -f "$work/stubs4/mkdir"; mv "$work/stubs4/mkdir2" "$work/stubs4/mkdir"
run_build --sha $SHA --n 1 --out-dir "$work/out4k" --engine docker
[ $rc -ne 0 ] && echo "$out" | grep -q 'Cannot create' && [ ! -e "$work/out4k/plane-fork-live.1.tar" ]; check "failing mkdir of out-dir: fatal, no tar" $?
stubs="$stubs_save"

# 5. podman path and autodetect
run_build --sha $SHA --n 1 --out-dir "$work/out5"
[ $rc -eq 0 ] && [ "$(calls_of podman)" -gt 0 ] && [ "$(calls_of docker)" -eq 0 ]; check "autodetect: podman preferred when both exist" $?
grep -q '^podman save -m --format docker-archive -o .*plane-fork-live.1.tar ' "$CALLS"; check "podman: save -m --format docker-archive" $?
[ "$(grep '^podman build ' "$CALLS" | grep -c -- '--cpu-period=100000 --cpu-quota=800000')" -eq 2 ]; check "podman: cpu cap on web and live only" $?
grep -q '^podman image prune -f --filter dangling=true --filter label=' "$CALLS"; check "podman: label-scoped prune" $?

# 6. verification failures after the builds
FAKE_IMAGES="localhost/plane-fork-web:v1.4.2-live.1" run_build --sha $SHA --n 1 --out-dir "$work/out6" --engine docker
[ $rc -ne 0 ] && readme_unchanged; check "missing images: non-zero, README untouched" $?

GIT_LSTREE_EXTRA=2 run_build --sha $SHA --n 1 --out-dir "$work/out7" --engine docker
[ $rc -ne 0 ] && echo "$out" | grep -q "Extraction check failed" && [ "$(calls_of docker)" -eq 0 ]; check "extraction count mismatch: refuses before building" $?

GIT_LSTREE_SUBMODULE=1 run_build --sha $SHA --n 1 --out-dir "$work/out8" --engine docker
[ $rc -eq 0 ]; check "submodule entries are not counted" $?

FAKE_PRUNE_RC=1 run_build --sha $SHA --n 1 --out-dir "$work/out9" --engine docker
[ $rc -eq 0 ] && grep -q 'Prune (.*): 0 image' "$repo/fork/README.md"; check "prune failure does not fail the build" $?

# 7. argument validation
run_build --n 1 --engine docker;                       [ $rc -ne 0 ]; check "args: --sha required" $?
run_build --sha $SHA --engine docker;                  [ $rc -ne 0 ]; check "args: --n required" $?
run_build --sha abc --n 1 --engine docker;             [ $rc -ne 0 ]; check "args: short sha rejected" $?
run_build --sha "${SHA^^}" --n 1 --engine docker;      [ $rc -ne 0 ]; check "args: uppercase sha rejected" $?
run_build --sha $SHA --n x --engine docker;            [ $rc -ne 0 ]; check "args: non-numeric n rejected" $?
run_build --sha $SHA --n 1 --engine rkt;               [ $rc -ne 0 ]; check "args: unknown engine rejected" $?
run_build --sha $SHA --n 1 --out-dir rel --engine docker; [ $rc -ne 0 ]; check "args: relative out-dir rejected" $?
run_build --sha $SHA --n 1 --bogus;                    [ $rc -ne 0 ]; check "args: unknown flag rejected" $?
[ ! -s "$CALLS" ]; check "args: nothing executed on bad args" $?

# 8. auto-proxy detection for loopback HTTPS_PROXY
# 8a. auto-enable for 127.0.0.1
HTTPS_PROXY=http://127.0.0.1:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8a" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: 127.0.0.1 auto-enables" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY')" -eq 2 ]; check "auto-proxy: 127.0.0.1 has proxy args on web and live" $?

# 8b. auto-enable for localhost
HTTPS_PROXY=http://localhost:3128 run_build --sha $SHA --n 1 --out-dir "$work/out8b" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: localhost auto-enables" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY')" -eq 2 ]; check "auto-proxy: localhost has proxy args" $?

# 8c. auto-enable for ::1 (IPv6)
HTTPS_PROXY='http://[::1]:8080' run_build --sha $SHA --n 1 --out-dir "$work/out8c" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: [::1] auto-enables" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY')" -eq 2 ]; check "auto-proxy: [::1] has proxy args" $?

# 8d. auto-enable for 127.0.0.0/8 range (e.g., 127.42.2.1)
HTTPS_PROXY=http://127.42.2.1:3128 run_build --sha $SHA --n 1 --out-dir "$work/out8d" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: 127.x.x.x auto-enables" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY')" -eq 2 ]; check "auto-proxy: 127.x.x.x has proxy args" $?

# 8e. auto-enable for URL with userinfo
HTTPS_PROXY='http://user:pass@127.0.0.1:8080' run_build --sha $SHA --n 1 --out-dir "$work/out8e" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: URL with userinfo auto-enables" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY')" -eq 2 ]; check "auto-proxy: URL with userinfo has proxy args" $?
! echo "$out" | grep -q 'user:pass'; check "auto-proxy: userinfo not printed in output" $?

# 8f. no auto-enable for non-loopback address
HTTPS_PROXY=http://192.168.1.1:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8f" --engine docker
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: non-loopback does not auto-enable" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host')" -eq 0 ]; check "auto-proxy: non-loopback has no proxy args" $?

# 8g. no auto-enable when no HTTPS_PROXY is set
unset HTTPS_PROXY https_proxy
run_build --sha $SHA --n 1 --out-dir "$work/out8g" --engine docker
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: no proxy env does not auto-enable" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host')" -eq 0 ]; check "auto-proxy: no proxy env has no proxy args" $?

# 8h. explicit --build-proxy overrides everything
run_build --sha $SHA --n 1 --out-dir "$work/out8h" --engine docker --build-proxy
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling"; check "auto-proxy: explicit --build-proxy does not print auto message" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY')" -eq 2 ]; check "auto-proxy: explicit --build-proxy has proxy args" $?

# 8i. explicit --no-build-proxy disables even with loopback proxy
HTTPS_PROXY=http://127.0.0.1:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8i" --engine docker --no-build-proxy
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: --no-build-proxy suppresses auto-enable" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host')" -eq 0 ]; check "auto-proxy: --no-build-proxy removes proxy args" $?

# 8j. https_proxy (lowercase) also triggers auto-detect
https_proxy=http://localhost:3128 HTTPS_PROXY= run_build --sha $SHA --n 1 --out-dir "$work/out8j" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: lowercase https_proxy auto-enables" $?

# 8k. case-insensitive localhost (LOCALHOST, Localhost, etc.)
HTTPS_PROXY=http://LOCALHOST:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8k" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: LOCALHOST (uppercase) auto-enables" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host --build-arg HTTPS_PROXY')" -eq 2 ]; check "auto-proxy: LOCALHOST has proxy args" $?

HTTPS_PROXY=http://Localhost:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8l" --engine docker
[ $rc -eq 0 ] && echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: Localhost (mixed case) auto-enables" $?

# 8m. invalid hostnames that look like loopback but are not
# 127.example.com should NOT auto-enable
HTTPS_PROXY=http://127.example.com:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8m" --engine docker
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: 127.example.com does not auto-enable" $?
[ "$(grep '^docker build ' "$CALLS" | grep -c -- '--network host')" -eq 0 ]; check "auto-proxy: 127.example.com has no proxy args" $?

# 127.0.0.1.evil.example should NOT auto-enable
HTTPS_PROXY=http://127.0.0.1.evil.example:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8n" --engine docker
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: 127.0.0.1.evil.example does not auto-enable" $?

# 1270.0.0.1 should NOT auto-enable (first octet > 255)
HTTPS_PROXY=http://1270.0.0.1:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8o" --engine docker
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: 1270.0.0.1 does not auto-enable" $?

# 127.256.0.1 should NOT auto-enable (second octet > 255)
HTTPS_PROXY=http://127.256.0.1:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8p" --engine docker
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: 127.256.0.1 (octet > 255) does not auto-enable" $?

# 127.0.0.256 should NOT auto-enable (fourth octet > 255)
HTTPS_PROXY=http://127.0.0.256:8080 run_build --sha $SHA --n 1 --out-dir "$work/out8q" --engine docker
[ $rc -eq 0 ] && ! echo "$out" | grep -q "Auto-enabling build proxy"; check "auto-proxy: 127.0.0.256 (octet > 255) does not auto-enable" $?

echo
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
