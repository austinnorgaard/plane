/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { describe, expect, it } from "vitest";
import { buildAllowlist, isOriginAllowed } from "@/events/origin";
import { parseEventsConfig } from "@/events/config";

const allow = buildAllowlist([
  "https://plane.example.com, http://lan.example.test ,,",
  "HTTPS://Plane.Example.com:443/",
]);
const ok = (origin: string | undefined, host?: string, xfh?: string, list = allow) =>
  isOriginAllowed({ origin, host, forwardedHost: xfh }, list);

describe("origin allowlist", () => {
  it("splits, trims, drops empties and normalises", () => {
    expect([...allow].toSorted()).toEqual(["http://lan.example.test", "https://plane.example.com"]);
  });

  it("accepts the public https origin when the tunnel rewrote Host", () => {
    expect(ok("https://plane.example.com", "upstream.example.test:8080")).toBe(true);
  });

  it("accepts the LAN http origin", () => {
    expect(ok("http://lan.example.test", "lan.example.test")).toBe(true);
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
    expect(ok("https://plane.example.com", "upstream.example.test", undefined, empty)).toBe(false);
  });

  it("host match ignores scheme and prefers the first X-Forwarded-Host value", () => {
    const empty = buildAllowlist([]);
    expect(ok("https://app.example.org", "upstream.example.test", "app.example.org, edge.example.test", empty)).toBe(
      true
    );
    expect(ok("https://app.example.org", "app.example.org", "other.example.org", empty)).toBe(false);
    expect(ok("http://app.example.org:8080", "app.example.org:8080", undefined, empty)).toBe(true);
    expect(ok("https://app.example.org:8443", "app.example.org", undefined, empty)).toBe(false);
  });

  it("reads CORS_ALLOWED_ORIGINS as part of the union, and an empty value adds nothing", () => {
    const cfg = parseEventsConfig({
      LIVE_EVENTS_ALLOWED_ORIGINS: "https://a.example.test",
      CORS_ALLOWED_ORIGINS: " https://cors.example.test ,, ",
      WEB_URL: "https://web.example.test",
    });
    const list = buildAllowlist([...cfg.allowedOrigins, ...cfg.corsOrigins, cfg.webUrl]);
    expect([...list].toSorted()).toEqual([
      "https://a.example.test",
      "https://cors.example.test",
      "https://web.example.test",
    ]);
    const empty = parseEventsConfig({ CORS_ALLOWED_ORIGINS: "" });
    expect(buildAllowlist([...empty.allowedOrigins, ...empty.corsOrigins, empty.webUrl]).size).toBe(0);
  });
});
