#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# test_override.sh - validate docker-compose.override.yaml against the upstream
# community compose file (deployments/cli/community/docker-compose.yml).
#
# 1. If `docker compose`, `podman compose` or `docker-compose` exists, runs
#    `config` with both -f files and dummy variables (this is the real merge),
#    and checks the merged result.
# 2. Always checks the override file itself with python3 + PyYAML: services
#    exist upstream, flags are on the right services, LIVE_BASE_URL only on
#    api, no CORS_ALLOWED_ORIGINS on live, image tags, one live replica.
# 3. --self-mutate runs the checks against deliberately broken copies and
#    requires every one of them to fail.
#
# Usage: fork/deploy/test_override.sh [--self-mutate]
# Uses dummy values only; needs no daemon and no network.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
UPSTREAM=$ROOT/deployments/cli/community/docker-compose.yml
OVERRIDE=${OVERRIDE:-$HERE/docker-compose.override.yaml}

for f in "$UPSTREAM" "$OVERRIDE"; do
  [ -f "$f" ] || { echo "missing file: $f" >&2; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "python3 with PyYAML is required" >&2; exit 1; }

export FORK_N=1 WEB_URL=https://plane.example.test \
  LIVE_EVENTS_ALLOWED_ORIGINS=https://plane.example.test \
  LIVE_SERVER_SECRET_KEY=dummy-not-a-secret SECRET_KEY=dummy-not-a-secret \
  CORS_ALLOWED_ORIGINS=https://plane.example.test

CHECK=$(mktemp)
trap 'rm -f "$CHECK"; [ -n "${MUT:-}" ] && rm -rf "$MUT"' EXIT
cat >"$CHECK" <<'PY'
import sys, yaml

upstream_path, path, mode = sys.argv[1], sys.argv[2], sys.argv[3]  # mode: raw | merged
errors = []
def err(m): errors.append(m)

def load(p):
    with open(p) as f:
        return yaml.safe_load(f)

def env_of(svc):
    e = (svc or {}).get("environment") or {}
    if isinstance(e, list):
        d = {}
        for item in e:
            k, _, v = str(item).partition("=")
            d[k] = v
        return d
    return {k: ("" if v is None else str(v)) for k, v in e.items()}

up = load(upstream_path)["services"]
doc = load(path)
svcs = doc.get("services") or {}
for name in svcs:
    if name not in up:
        err(f"service {name!r} does not exist in the upstream compose file")

FIVE = ["web", "live", "api", "worker", "beat-worker"]
for name in FIVE:
    if name not in up:
        err(f"upstream has no service {name!r}")
    if name not in svcs:
        err(f"service {name!r} missing")
        continue

IMG = {"web": "localhost/plane-fork-web:v1.4.2-live.", "live": "localhost/plane-fork-live:v1.4.2-live.",
       "api": "localhost/plane-fork-api:v1.4.2-live.", "worker": "localhost/plane-fork-api:v1.4.2-live.",
       "beat-worker": "localhost/plane-fork-api:v1.4.2-live."}
for name, prefix in IMG.items():
    image = str((svcs.get(name) or {}).get("image", ""))
    if not image.startswith(prefix):
        err(f"{name}: image {image!r} should start with {prefix!r}")
    if mode == "merged" and "$" in image:
        err(f"{name}: image tag not resolved")

E = {n: env_of(svcs.get(n)) for n in svcs}
for n in ("api", "worker", "live"):
    if E.get(n, {}).get("LIVE_EVENTS_ENABLED") != "1":
        err(f"{n}: LIVE_EVENTS_ENABLED must be 1")
for n in ("api", "live"):
    if E.get(n, {}).get("PAGES_API_ENABLED") != "1":
        err(f"{n}: PAGES_API_ENABLED must be 1")
for n in svcs:
    if n not in ("api", "live") and "PAGES_API_ENABLED" in E[n]:
        err(f"{n}: PAGES_API_ENABLED must not be set")
    if n not in ("api", "worker", "live") and "LIVE_EVENTS_ENABLED" in E[n]:
        err(f"{n}: LIVE_EVENTS_ENABLED must not be set")
    if n != "api" and "LIVE_BASE_URL" in E[n]:
        err(f"{n}: LIVE_BASE_URL must be set on api only")
if E.get("api", {}).get("LIVE_BASE_URL") != "http://live:3000":
    err("api: LIVE_BASE_URL must be http://live:3000")
live = E.get("live", {})
if not live.get("LIVE_EVENTS_ALLOWED_ORIGINS"):
    err("live: LIVE_EVENTS_ALLOWED_ORIGINS missing or empty")
if not live.get("WEB_URL"):
    err("live: WEB_URL missing or empty")
if "CORS_ALLOWED_ORIGINS" in live:
    err("live: CORS_ALLOWED_ORIGINS must not be set")
if mode == "merged":
    # stock envs merged in: the fork must not have pulled CORS into live, and secrets stay wired
    if not live.get("LIVE_SERVER_SECRET_KEY"):
        err("live: LIVE_SERVER_SECRET_KEY missing after merge")
    for n in ("worker", "beat-worker"):
        if "LIVE_BASE_URL" in E.get(n, {}):
            err(f"{n}: LIVE_BASE_URL present after merge")
reps = ((svcs.get("live") or {}).get("deploy") or {}).get("replicas")
if reps is not None and str(reps) != "1":
    err(f"live: replicas must be 1, got {reps}")

if errors:
    print("\n".join("  - " + e for e in errors))
    sys.exit(1)
PY

# find a compose provider
PROVIDER=()
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then PROVIDER=(docker compose)
elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then PROVIDER=(podman compose)
elif command -v docker-compose >/dev/null 2>&1; then PROVIDER=(docker-compose)
fi

# run_checks <override-file>; returns 0 only if every applicable check passes
run_checks() {
  local ov=$1 rc=0
  if ! python3 "$CHECK" "$UPSTREAM" "$ov" raw; then rc=1; fi
  if [ "${#PROVIDER[@]}" -gt 0 ]; then
    local merged
    merged=$(mktemp)
    if "${PROVIDER[@]}" -f "$UPSTREAM" -f "$ov" config >"$merged" 2>"$merged.err"; then
      if ! python3 "$CHECK" "$UPSTREAM" "$merged" merged; then rc=1; fi
    else
      echo "  - '${PROVIDER[*]} config' failed:"; sed 's/^/    /' "$merged.err" | head -20; rc=1
    fi
    rm -f "$merged" "$merged.err"
  fi
  return $rc
}

if [ "${#PROVIDER[@]}" -gt 0 ]; then
  echo "compose provider: ${PROVIDER[*]} (config runs against both files)"
else
  echo "no compose provider found: checking the override with python3 + PyYAML only"
fi

if run_checks "$OVERRIDE"; then echo "PASS: $OVERRIDE"; else echo "FAIL: $OVERRIDE"; exit 1; fi

[ "${1:-}" = "--self-mutate" ] || exit 0

MUT=$(mktemp -d)
fail=0
mutate() { # mutate <name> <python-expression on dict d>
  python3 - "$OVERRIDE" "$MUT/$1.yaml" "$2" <<'PY'
import sys, yaml
src, dst, code = sys.argv[1:4]
d = yaml.safe_load(open(src))
exec(code)
yaml.safe_dump(d, open(dst, "w"))
PY
  if run_checks "$MUT/$1.yaml" >/dev/null 2>&1; then echo "MUTATION NOT CAUGHT: $1"; fail=1; else echo "mutation caught: $1"; fi
}
mutate worker_live_base_url 'd["services"]["worker"]["environment"]["LIVE_BASE_URL"]="http://live:3000"'
mutate beat_live_base_url   'd["services"]["beat-worker"].setdefault("environment",{})["LIVE_BASE_URL"]="http://live:3000"'
mutate live_cors            'd["services"]["live"]["environment"]["CORS_ALLOWED_ORIGINS"]="${CORS_ALLOWED_ORIGINS}"'
mutate api_no_pages_flag    'del d["services"]["api"]["environment"]["PAGES_API_ENABLED"]'
mutate worker_pages_flag    'd["services"]["worker"]["environment"]["PAGES_API_ENABLED"]="1"'
mutate worker_no_events     'del d["services"]["worker"]["environment"]["LIVE_EVENTS_ENABLED"]'
mutate live_no_origins      'del d["services"]["live"]["environment"]["LIVE_EVENTS_ALLOWED_ORIGINS"]'
mutate unknown_service      'd["services"]["nosuch"]={"image":"x"}'
mutate stock_image          'd["services"]["web"]["image"]="makeplane/plane-frontend:stable"'
mutate live_two_replicas    'd["services"]["live"]["deploy"]={"replicas":2}'
exit $fail
