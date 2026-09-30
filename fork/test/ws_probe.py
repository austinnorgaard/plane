#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""ws_probe.py - minimal stdlib WebSocket client for fork/test/local-stack.sh.

It talks to the live events socket (`<base path>/events`, frames documented in
apps/live/src/events/hub.ts) through the local proxy, so nothing but python3 is
needed on the host. Secrets are read from the environment and never printed:

  WS_COOKIE     value of the Cookie header (`session-id=<value>`); optional
  WS_API_KEY    X-API-Key for the PATCH used by --mode latency

Prints exactly one JSON line on stdout and always exits 0 when it could run at
all (the caller decides PASS/FAIL from the JSON); exit 2 is a usage error.

  --mode connect   connect (optionally with --project/--slug subscribe) and
                   report the close code and the subscribed/denied ids.
  --mode latency   subscribe, wait for "subscribed", PATCH the URL in
                   --patch-url with --patch-body, then report how many seconds
                   passed until an "events" frame naming --issue arrived.
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class Closed(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class WS:
    def __init__(self, url, origin, cookie, timeout):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {u.path or '/'}{'?' + u.query if u.query else ''} HTTP/1.1",
            f"Host: {u.netloc}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if origin:
            lines.append(f"Origin: {origin}")
        if cookie:
            lines.append(f"Cookie: {cookie}")
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            head += chunk
        head, _, self.buf = head.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode("latin-1")
        self.status = int(status.split()[1]) if status.startswith("HTTP/") else 0

    def send_text(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            header = struct.pack("!BB", 0x81, 0x80 | n)
        else:
            header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(header + mask + masked)

    def _need(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed(None)
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv_text(self):
        """Next text frame as str. Raises Closed(code) on a close frame or EOF."""
        while True:
            b0, b1 = self._need(2)
            op = b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                (n,) = struct.unpack("!H", self._need(2))
            elif n == 127:
                (n,) = struct.unpack("!Q", self._need(8))
            payload = self._need(n)
            if op == 8:
                raise Closed(struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None)
            if op == 9:  # ping -> masked pong
                mask = os.urandom(4)
                body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                self.sock.sendall(struct.pack("!BB", 0x8A, 0x80 | len(payload)) + mask + body)
                continue
            if op == 1:
                return payload.decode()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def patch(url, body, key):
    req = urllib.request.Request(
        url,
        data=body.encode(),
        method="PATCH",
        headers={"Content-Type": "application/json", "X-API-Key": key},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status
    except urllib.error.HTTPError as err:
        return err.code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["connect", "latency"], required=True)
    ap.add_argument("--url", required=True, help="ws://host:port/live/events")
    ap.add_argument("--origin", default="")
    ap.add_argument("--slug", default="")
    ap.add_argument("--project", default="")
    ap.add_argument("--issue", default="")
    ap.add_argument("--patch-url", default="")
    ap.add_argument("--patch-body", default="")
    ap.add_argument("--timeout", type=float, default=10.0)
    a = ap.parse_args()

    cookie = os.environ.get("WS_COOKIE", "")
    key = os.environ.get("WS_API_KEY", "")
    out = {"mode": a.mode, "http_status": None, "close": None, "subscribed": [], "denied": []}
    try:
        ws = WS(a.url, a.origin, cookie, a.timeout)
    except OSError as err:
        out["error"] = f"connect failed: {type(err).__name__}"
        print(json.dumps(out))
        return 0
    out["http_status"] = ws.status
    if ws.status != 101:
        print(json.dumps(out))
        return 0

    deadline = time.monotonic() + a.timeout
    try:
        if a.project:
            ws.send_text(json.dumps({"type": "subscribe", "workspace_slug": a.slug, "project_ids": [a.project]}))
        subscribed = not a.project
        t0 = None
        while time.monotonic() < deadline:
            ws.sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                frame = json.loads(ws.recv_text())
            except socket.timeout:
                break
            kind = frame.get("type")
            if kind == "ping":
                ws.send_text(json.dumps({"type": "pong"}))
            elif kind == "subscribed":
                out["subscribed"] = frame.get("project_ids", [])
                out["denied"] = frame.get("denied", [])
                subscribed = True
                if a.mode == "connect":
                    break
                t0 = time.monotonic()
                out["patch_status"] = patch(a.patch_url, a.patch_body, key)
            elif kind == "events" and a.mode == "latency" and t0 is not None:
                ids = [i.get("issue_id") for i in frame.get("items", [])]
                if frame.get("project_id") == a.project and (a.issue in ids or frame.get("full_refresh")):
                    out["latency"] = round(time.monotonic() - t0, 3)
                    break
        if a.mode == "connect" and not subscribed:
            out["error"] = "no subscribed frame"
    except Closed as closed:
        out["close"] = closed.code
    except (OSError, ValueError) as err:
        out["error"] = type(err).__name__
    finally:
        ws.close()
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
