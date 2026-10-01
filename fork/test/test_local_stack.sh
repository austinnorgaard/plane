#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# test_local_stack.sh - offline tests for fork/test/local-stack.sh and ws_probe.py.
#
# podman, docker, docker-compose, podman-compose, curl and sleep are replaced by stubs that come
# first on PATH, and the host environment is scrubbed, so the result does not depend on a
# container engine, a running stack or exported variables on the machine. Covers:
#   - the env file is generated with a random secret and is not overwritten silently
#   - `up` seeds the state file through the stubbed api container
#   - `down` passes the volume-removal flag and deletes the state file
#   - `smoke` exits 0 when every stubbed answer is right and non-zero when any check fails
#   - the generated files are gitignored
#   - ws_probe.py speaks the live events protocol against a fake server
# Usage: fork/test/test_local_stack.sh        (exit 0 = all tests passed)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/local-stack.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0
PASSES=0

# ---- hermetic environment: nothing from the host may steer local-stack.sh or the stubs
unset CONTAINER_ENGINE COMPOSE_CMD COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES \
  DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG CONTAINER_HOST WS_COOKIE
for v in $(compgen -v | grep -E '^(STUB_|LOCAL_STACK_)'); do unset "$v"; done
export FORK_N=1
# a project name no real stack uses: engine queries by compose project label can never match
# containers of a stack running on this machine
export LOCAL_STACK_PROJECT="plane-lu-test-$$"

check() { # check NAME CONDITION_EXIT_CODE
  if [ "$2" -eq 0 ]; then
    PASSES=$((PASSES + 1))
    echo "ok   $1"
  else
    FAILS=$((FAILS + 1))
    echo "FAIL $1"
  fi
}
has() { grep -q -- "$2" "$1"; }

mkdir -p "$T/bin"

# ---- stub: podman. `compose version` works; other calls are logged; exec answers by content
cat >"$T/bin/podman" <<'STUB'
#!/usr/bin/env bash
echo "podman $*" >>"$STUB_DIR/podman.log"
case "$*" in
  "compose version"*) exit 0 ;;
  "image exists "*) [ -z "${STUB_MISSING_IMAGE:-}" ]; exit $? ;;
esac
args=" $* "
if [[ $args == *" -f "*"local-stack.l1.yaml"* ]]; then echo l1 >"$STUB_DIR/phase"
elif [[ $args == *"docker-compose.override.yaml"* ]]; then echo fork >"$STUB_DIR/phase"
elif [[ $args == *" up "* ]]; then echo stock >"$STUB_DIR/phase"; fi
phase=$(cat "$STUB_DIR/phase" 2>/dev/null || echo fork)
case "$args" in
  *" ps --filter "*)
    [ -n "${STUB_NO_IMAGES:-}" ] && exit 0
    if [ "$phase" = stock ]; then
      for s in web live api worker beat-worker proxy; do echo "makeplane/plane-$s:v1.4.2"; done
    else
      for s in web live api worker beat-worker; do echo "localhost/plane-fork-$s:v1.4.2-live.1"; done
      echo "makeplane/plane-proxy:v1.4.2"
    fi ;;
  *" exec "*"manage.py shell"*)
    if [[ $* == *"PROJECT_ID ="* ]]; then echo "STATE MEMBERS_SEEDED=1"; exit 0; fi
    for n in ADMIN MEMBER GUEST NONMEMBER; do
      echo "STATE ${n}_EMAIL=lu-$n@example.test"
      echo "STATE ${n}_PASSWORD=pw-$n"
      echo "STATE ${n}_KEY=key-$n"
      echo "STATE ${n}_SESSION=sess-$n"
    done
    echo "STATE WORKSPACE_SLUG=lu-local" ;;
  *" exec "*)
    if [ -n "${STUB_GUARD_BAD:-}" ]; then
      echo "GUARD loaded_nokey=200 loaded_key=200 loaded_xff=403 rebase_nokey=401 loaded_body={\"loaded\":false}"
    else
      echo "GUARD loaded_nokey=401 loaded_key=200 loaded_xff=403 rebase_nokey=401 loaded_body={\"loaded\":false}"
    fi ;;
esac
exit 0
STUB

# ---- stub: curl. Answers by method and url; the API key comes from the -H @file header
cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET out="" hdr="" url="" write=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    -o) out=$2; shift ;;
    -w) write=$2; shift ;;
    -H) case "$2" in @*) hdr=${2#@} ;; esac; shift ;;
    -m | --data) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
key=""
[ -n "$hdr" ] && key=$(sed 's/^X-API-Key: //' "$hdr")
phase=$(cat "$STUB_DIR/phase" 2>/dev/null || echo fork)
code=200 body='{}'
case "$method $url" in
  "GET "*/api/instances/ | "GET "*/live/health) code=200 ;;
  "POST "*/projects/) code=201 body='{"id":"11111111-1111-4111-8111-111111111111"}' ;;
  "POST "*/issues/) code=201 body='{"id":"22222222-2222-4222-8222-222222222222"}' ;;
  "PATCH "*/issues/*) code=200 ;;
  "POST "*/pages/)
    if [ "$key" = key-MEMBER ] && [ -z "${STUB_FAIL_PAGES:-}" ]; then code=201 body='{"id":"33333333-3333-4333-8333-333333333333"}'
    elif [ "$key" = key-MEMBER ]; then code=500
    else code=403; fi
    [ "$code" = 201 ] && echo "lu-original" >"$STUB_DIR/page" ;;
  "GET "*/pages/)
    case "$key:$phase" in
      key-NONMEMBER:*) code=403 ;;
      key-MEMBER:l1 | key-MEMBER:stock) code=404 ;;
    esac ;;
  "GET "*/pages/3333*) body="{\"description_html\":\"<p>$(cat "$STUB_DIR/page")</p>\"}" ;;
  "PATCH "*/pages/*)
    if [ "$key" = key-MEMBER ]; then echo "lu-changed" >"$STUB_DIR/page"; else code=403; fi ;;
  "GET "*/live/fork/pages/*) code=403 ;;
  "POST "*/live/fork/pages/rebase) code=403 ;;
esac
[ -n "$out" ] && [ "$out" != /dev/null ] && printf '%s' "$body" >"$out"
[ -n "$write" ] && printf '%s' "$code"
exit 0
STUB

printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"

# ---- stubs for every other engine and compose front end the script may probe, so a real one
# on the host is never reached. They log the call and fail like an engine that is not running.
for name in docker docker-compose podman-compose; do
  cat >"$T/bin/$name" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$STUB_DIR/other-engines.log"
exit 1
STUB
done

# ---- stub: ws_probe.py
cat >"$T/probe.py" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
def opt(n):
    return a[a.index(n) + 1] if n in a else ""
phase = open(os.environ["STUB_DIR"] + "/phase").read().strip() if os.path.exists(os.environ["STUB_DIR"] + "/phase") else "fork"
cookie = os.environ.get("WS_COOKIE", "")
project = opt("--project")
out = {"http_status": 101, "close": None, "subscribed": [], "denied": []}
if opt("--mode") == "latency":
    out.update(subscribed=[project], patch_status=200, latency=float(os.environ.get("STUB_LATENCY", "0.4")))
elif "foreign" in opt("--origin"):
    out["close"] = 4403
elif phase == "l1":
    out["close"] = 4404
elif phase == "stock":
    # Stock image: accepts the upgrade (101) and normally never answers the subscribe
    out["http_status"] = int(os.environ.get("STUB_STOCK_HTTP", "101"))
    if os.environ.get("STUB_STOCK_SUBSCRIBED") == "1":
        out["subscribed"] = [project]
    else:
        # Silent accept: upgrade succeeds but no frame sent (timeout)
        pass
elif "GUEST" in cookie or "NONMEMBER" in cookie:
    out["denied"] = [project]
else:
    out["subscribed"] = [project]
print(json.dumps(out))
STUB
chmod +x "$T"/bin/* "$T/probe.py"

export STUB_DIR=$T
export PATH="$T/bin:$PATH"
hash -r
: >"$T/other-engines.log"
for name in podman docker docker-compose podman-compose curl sleep; do
  check "stub $name wins over any host binary on PATH" "$([ "$(command -v "$name")" = "$T/bin/$name" ] && echo 0 || echo 1)"
done
export LOCAL_STACK_WS_PROBE=$T/probe.py

new_dir() { rm -rf "$T/d"; mkdir -p "$T/d"; export LOCAL_STACK_DIR=$T/d; : >"$T/podman.log"; rm -f "$T/phase"; }
envval() { grep -m1 "^$1=" "$LOCAL_STACK_DIR/local-stack.env" | cut -d= -f2-; }

# ------------------------------------------------------------------ env file
new_dir
"$SCRIPT" up >"$T/up1.out" 2>&1
check "up exits 0 with the stubs" $?
check "env file exists" "$([ -f "$T/d/local-stack.env" ] && echo 0 || echo 1)"
check "env file mode is 600" "$([ "$(stat -c %a "$T/d/local-stack.env")" = 600 ] && echo 0 || echo 1)"
secret1=$(envval LIVE_SERVER_SECRET_KEY)
check "LIVE_SERVER_SECRET_KEY is 64 hex chars" "$([[ $secret1 =~ ^[0-9a-f]{64}$ ]] && echo 0 || echo 1)"
check "SECRET_KEY is 64 hex chars and differs from the live key" "$([[ $(envval SECRET_KEY) =~ ^[0-9a-f]{64}$ && $(envval SECRET_KEY) != "$secret1" ]] && echo 0 || echo 1)"
check "WEB_URL is the local url" "$([ "$(envval WEB_URL)" = http://localhost:18080 ] && echo 0 || echo 1)"
check "LIVE_EVENTS_ALLOWED_ORIGINS is the local url" "$([ "$(envval LIVE_EVENTS_ALLOWED_ORIGINS)" = http://localhost:18080 ] && echo 0 || echo 1)"
check "env file has no host other than localhost" "$(grep -v '^#' "$T/d/local-stack.env" | grep -E 'https?://' | grep -qvE 'localhost|acme-v02' && echo 1 || echo 0)"
check "secret is not printed by up" "$(grep -q "$secret1" "$T/up1.out" && echo 1 || echo 0)"
check "state file has the four users' keys" "$([ "$(grep -c '_KEY=key-' "$T/d/local-stack.state")" = 4 ] && echo 0 || echo 1)"
check "state file has project and issue ids" "$(grep -q '^PROJECT_ID=' "$T/d/local-stack.state" && grep -q '^ISSUE_ID=' "$T/d/local-stack.state" && echo 0 || echo 1)"
check "state file mode is 600" "$([ "$(stat -c %a "$T/d/local-stack.state")" = 600 ] && echo 0 || echo 1)"

"$SCRIPT" up >"$T/up2.out" 2>&1
check "second up keeps the existing secret" "$([ "$(envval LIVE_SERVER_SECRET_KEY)" = "$secret1" ] && echo 0 || echo 1)"
check "second up says it kept the file" "$(has "$T/up2.out" 'keeping existing' && echo 0 || echo 1)"
"$SCRIPT" up --regenerate-env >"$T/up3.out" 2>&1
check "up --regenerate-env writes a new secret" "$([ "$(envval LIVE_SERVER_SECRET_KEY)" != "$secret1" ] && echo 0 || echo 1)"
check "up --regenerate-env announces it" "$(has "$T/up3.out" 'wrote local-stack.env' && echo 0 || echo 1)"
secret2=$(envval LIVE_SERVER_SECRET_KEY)
new_dir
"$SCRIPT" up >/dev/null 2>&1
check "two fresh env files get different secrets" "$([ "$(envval LIVE_SERVER_SECRET_KEY)" != "$secret2" ] && [ "$(envval LIVE_SERVER_SECRET_KEY)" != "$secret1" ] && echo 0 || echo 1)"
check "up runs compose config -q first" "$(has "$T/podman.log" 'config -q' && echo 0 || echo 1)"
check "up uses both compose files" "$(has "$T/podman.log" 'docker-compose.yml -f .*docker-compose.override.yaml' && echo 0 || echo 1)"

# ------------------------------------------------------------------ gitignore
cd "$HERE/../.." || exit 2
ign=0
for f in local-stack.env local-stack.state local-stack.report local-stack.l1.yaml local-stack.extra.yaml; do
  git check-ignore -q "fork/test/$f" || ign=1
done
check "generated files are gitignored" "$ign"

# ------------------------------------------------------------------ smoke
new_dir
"$SCRIPT" up >/dev/null 2>&1
: >"$T/podman.log"
"$SCRIPT" smoke >"$T/smoke.out" 2>&1
rc=$?
check "smoke exits 0 when every check passes" "$rc"
check "smoke printed PASS lines and no FAIL line" "$(has "$T/smoke.out" '^PASS ' && ! has "$T/smoke.out" '^FAIL ' && echo 0 || echo 1)"
check "smoke ran L1 and L2" "$(has "$T/smoke.out" 'L1 pages API answers 404' && has "$T/smoke.out" 'L2: no service runs a fork image' && echo 0 || echo 1)"
check "smoke prints the manual browser steps" "$(has "$T/smoke.out" 'MANUAL STEPS' && has "$T/smoke.out" 'exactly once' && echo 0 || echo 1)"
check "smoke report file written" "$(has "$T/d/local-stack.report" 'SUMMARY: ' && echo 0 || echo 1)"
check "smoke output has no key or session values" "$(grep -qE 'key-|sess-|pw-' "$T/smoke.out" "$T/d/local-stack.report" && echo 1 || echo 0)"
check "smoke output has no url or address" "$(grep -qE 'https?://|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$T/d/local-stack.report" && echo 1 || echo 0)"

new_dir
"$SCRIPT" up >/dev/null 2>&1
STUB_FAIL_PAGES=1 "$SCRIPT" smoke >"$T/smoke-fail1.out" 2>&1
rc=$?
check "a failing pages check makes smoke exit non-zero" "$([ "$rc" -ne 0 ] && has "$T/smoke-fail1.out" '^FAIL pages create' && echo 0 || echo 1)"
STUB_LATENCY=3.1 "$SCRIPT" smoke >"$T/smoke-fail2.out" 2>&1
rc=$?
check "a frame slower than 2 s makes smoke exit non-zero" "$([ "$rc" -ne 0 ] && has "$T/smoke-fail2.out" '^FAIL issue PATCH' && echo 0 || echo 1)"
STUB_GUARD_BAD=1 "$SCRIPT" smoke >"$T/smoke-fail3.out" 2>&1
rc=$?
check "a live guard answering 200 without a key makes smoke exit non-zero" "$([ "$rc" -ne 0 ] && has "$T/smoke-fail3.out" '^FAIL direct live /loaded without key' && echo 0 || echo 1)"

# ------------------------------------------------------------------ provider-independent switching
new_dir
"$SCRIPT" up >/dev/null 2>&1
: >"$T/podman.log"
"$SCRIPT" smoke >/dev/null 2>&1
ups=$(grep -c ' up -d ' "$T/podman.log")
noflag=$(grep ' up -d ' "$T/podman.log" | grep -vc -- '--force-recreate --no-deps')
check "smoke switches L1, roll forward, L2, roll forward with up -d (4 calls)" "$([ "$ups" = 4 ] && echo 0 || echo 1)"
check "every smoke up -d passes --force-recreate and --no-deps" "$([ "$noflag" = 0 ] && echo 0 || echo 1)"
check "L1 switch names api worker live" "$(grep ' up -d ' "$T/podman.log" | head -n 1 | grep -q -- '--no-deps api worker live$' && echo 0 || echo 1)"
check "L2 switch names all five overridden services" "$(grep ' up -d ' "$T/podman.log" | sed -n 3p | grep -q -- '--no-deps web live api worker beat-worker$' && echo 0 || echo 1)"

STUB_NO_IMAGES=1 "$SCRIPT" smoke >"$T/smoke-noimg.out" 2>&1
rc=$?
check "no image list makes the image checks FAIL, not pass" "$([ "$rc" -ne 0 ] && grep -c 'image list unavailable' "$T/smoke-noimg.out" | grep -q '^3$' && echo 0 || echo 1)"
check "the no-image case consulted the stubbed docker, not a host engine" "$(grep -q '^docker ps ' "$T/other-engines.log" && echo 0 || echo 1)"

# ------------------------------------------------------------------ precheck of the fork images
new_dir
STUB_MISSING_IMAGE=1 "$SCRIPT" up >"$T/up-missing.out" 2>&1
rc=$?
check "up stops when a fork image is missing" "$([ "$rc" -ne 0 ] && has "$T/up-missing.out" 'missing image localhost/plane-fork-web:v1.4.2-live.1' && echo 0 || echo 1)"
check "up did not start the stack when an image is missing" "$(grep -q ' up -d' "$T/podman.log" && echo 1 || echo 0)"

# ------------------------------------------------------------------ down
new_dir
"$SCRIPT" up >/dev/null 2>&1
: >"$T/podman.log"
"$SCRIPT" down >"$T/down.out" 2>&1
check "down exits 0" $?
check "down passes -v (volume removal)" "$(grep ' down ' "$T/podman.log" | grep -q ' -v' && echo 0 || echo 1)"
check "down deletes the state file" "$([ ! -f "$T/d/local-stack.state" ] && echo 0 || echo 1)"

# ------------------------------------------------------------------ smoke without state
new_dir
"$SCRIPT" smoke >/dev/null 2>&1
rc=$?
check "smoke without a state file exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# ------------------------------------------------------------------ L2 events socket check, through smoke
l2_smoke() { # l2_smoke OUTFILE [ENV=VALUE...]; runs the real smoke with the stubbed probe
  local o=$1
  shift
  new_dir
  "$SCRIPT" up >/dev/null 2>&1
  env "$@" "$SCRIPT" smoke >"$o" 2>&1
}
l2_smoke "$T/l2-silent.out"
rc=$?
check "L2 silent accept (101, no frame): smoke exits 0" "$rc"
check "L2 silent accept: PASS L2 events socket not available" "$(has "$T/l2-silent.out" '^PASS L2 events socket not available' && echo 0 || echo 1)"
l2_smoke "$T/l2-sub.out" STUB_STOCK_SUBSCRIBED=1
rc=$?
check "L2 subscribed frame: smoke exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "L2 subscribed frame: FAIL L2 events socket not available" "$(has "$T/l2-sub.out" '^FAIL L2 events socket not available' && echo 0 || echo 1)"
check "L2 subscribed frame: it is the only FAIL line" "$([ "$(grep -c '^FAIL ' "$T/l2-sub.out")" = 1 ] && echo 0 || echo 1)"
l2_smoke "$T/l2-502.out" STUB_STOCK_HTTP=502
rc=$?
check "L2 non-101 answer: smoke exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "L2 non-101 answer: FAIL L2 events socket not available, with http=502" "$(has "$T/l2-502.out" '^FAIL L2 events socket not available.*http=502' && echo 0 || echo 1)"

# ------------------------------------------------------------------ ws_probe against a fake server
python3 - "$HERE/ws_probe.py" <<'PY'
import base64, hashlib, http.server, json, os, socket, struct, subprocess, sys, threading

probe = sys.argv[1]
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
patched = threading.Event()


class Patch(http.server.BaseHTTPRequestHandler):
    def do_PATCH(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        patched.set()
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *a):
        pass


def frame(text, op=1):
    data = text if isinstance(text, bytes) else text.encode()
    if len(data) < 126:
        return struct.pack("!BB", 0x80 | op, len(data)) + data
    return struct.pack("!BBH", 0x80 | op, 126, len(data)) + data


def read_frame(conn):
    b = conn.recv(2)
    n = b[1] & 0x7F
    mask = conn.recv(4)
    data = b""
    while len(data) < n:
        data += conn.recv(n - len(data))
    return bytes(x ^ mask[i % 4] for i, x in enumerate(data)).decode()


def serve(srv, seen):
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        head = b""
        while b"\r\n\r\n" not in head:
            head += conn.recv(4096)
        text = head.decode()
        hdr = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in text.split("\r\n")[1:] if ":" in l}
        seen.append(hdr)
        acc = base64.b64encode(hashlib.sha1((hdr["sec-websocket-key"] + GUID).encode()).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        if hdr.get("origin") != "http://ok.local":
            conn.sendall(frame(struct.pack("!H", 4403) + b"origin not allowed", op=8))
            conn.close()
            continue
        msg = json.loads(read_frame(conn))
        pid = msg["project_ids"][0]
        if "cookie" in hdr and "guest" in hdr["cookie"]:
            conn.sendall(frame(json.dumps({"type": "subscribed", "project_ids": [], "denied": [pid]})))
            conn.close()
            continue
        conn.sendall(frame(json.dumps({"type": "subscribed", "project_ids": [pid], "denied": []})))
        if patched.wait(3):
            conn.sendall(frame(json.dumps({"type": "events", "project_id": pid, "items": [{"issue_id": "ISS", "kinds": ["issue"], "verbs": ["updated"], "actor_ids": []}]})))
        conn.close()
        patched.clear()


def run(*args, env=None):
    e = dict(os.environ, **(env or {}))
    out = subprocess.run([sys.executable, probe, *args], capture_output=True, text=True, timeout=30, env=e).stdout
    return json.loads(out)


srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(5)
seen = []
threading.Thread(target=serve, args=(srv, seen), daemon=True).start()
web = http.server.HTTPServer(("127.0.0.1", 0), Patch)
threading.Thread(target=web.serve_forever, daemon=True).start()
url = "ws://127.0.0.1:%d/live/events" % srv.getsockname()[1]
patch_url = "http://127.0.0.1:%d/x" % web.server_address[1]
bad = 0


def expect(name, cond):
    global bad
    print(("ok   " if cond else "FAIL ") + name)
    bad += 0 if cond else 1


r = run("--mode", "connect", "--url", url, "--origin", "http://foreign.local", "--timeout", "5")
expect("ws_probe reports close code 4403 for a foreign Origin", r["close"] == 4403)
r = run("--mode", "connect", "--url", url, "--origin", "http://ok.local", "--slug", "s", "--project", "P1",
        env={"WS_COOKIE": "session-id=member"})
expect("ws_probe reports the granted project", r["subscribed"] == ["P1"] and r["denied"] == [])
expect("ws_probe sent the Cookie header", seen[-1].get("cookie") == "session-id=member")
r = run("--mode", "connect", "--url", url, "--origin", "http://ok.local", "--slug", "s", "--project", "P1",
        env={"WS_COOKIE": "session-id=guest"})
expect("ws_probe reports a denied project", r["denied"] == ["P1"] and r["subscribed"] == [])
r = run("--mode", "latency", "--url", url, "--origin", "http://ok.local", "--slug", "s", "--project", "P1", "--issue", "ISS",
        "--patch-url", patch_url, "--patch-body", "{}", env={"WS_API_KEY": "k"})
expect("ws_probe latency mode sees the frame after the PATCH", r.get("patch_status") == 200 and r.get("latency") is not None and r["latency"] < 2)
sys.exit(1 if bad else 0)
PY
check "ws_probe tests" $?

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
