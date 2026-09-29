/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { describe, expect, it } from "vitest";
import { buildAllowlist, isOriginAllowed } from "@/events/origin";
import { parseEventsConfig } from "@/events/config";

const allow = buildAllowlist(["https://plane.example.com, http://192.0.2.10 ,,", "HTTPS://Plane.Example.com:443/"]);
const ok = (origin: string | undefined, host?: string, xfh?: string, list = allow) =>
  isOriginAllowed({ origin, host, forwardedHost: xfh }, list);

describe("origin allowlist", () => {
  it("splits, trims, drops empties and normalises", () => {
    expect([...allow].toSorted()).toEqual(["http://192.0.2.10", "https://plane.example.com"]);
  });

  it("accepts the public https origin when the tunnel rewrote Host", () => {
    expect(ok("https://plane.example.com", "127.0.0.1:8080")).toBe(true);
  });

  it("accepts the LAN http origin", () => {
    expect(ok("http://192.0.2.10", "192.0.2.10")).toBe(true);
  });

  it("rejects a foreign origin", () => {
    expect(ok("https://evil.example.net", "plane.example.com")).toBe(false);
  });

  it("rejects a missing Origin and the literal null", () => {
    expect(ok(undefined, "plane.example.com")).toBe(false);
    expect(ok("null", "plane.example.com")).toBe(false);
  });

  it("with an empty allowlist only host equality passes", () => {
    const empty = buildAllowlist(["", " , "]);
    expect(empty.size).toBe(0);
    expect(ok("https://plane.example.com", "plane.example.com", undefined, empty)).toBe(true);
    expect(ok("https://plane.example.com", "127.0.0.1", undefined, empty)).toBe(false);
  });

  it("host match ignores scheme and prefers the first X-Forwarded-Host value", () => {
    const empty = buildAllowlist([]);
    expect(ok("https://app.example.org", "10.0.0.5", "app.example.org, proxy.internal", empty)).toBe(true);
    expect(ok("https://app.example.org", "app.example.org", "other.example.org", empty)).toBe(false);
    expect(ok("http://app.example.org:8080", "app.example.org:8080", undefined, empty)).toBe(true);
    expect(ok("https://app.example.org:8443", "app.example.org", undefined, empty)).toBe(false);
  });

  it("does not read CORS_ALLOWED_ORIGINS", () => {
    const cfg = parseEventsConfig({ CORS_ALLOWED_ORIGINS: "https://cors.example.net" });
    expect(JSON.stringify(cfg)).not.toContain("cors.example.net");
  });
});
