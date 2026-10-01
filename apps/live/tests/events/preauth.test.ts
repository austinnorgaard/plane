/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildTrustedProxies, isPrivateAddress, resolveClientAddress } from "@/events/address";
import type { EventsAuthApi } from "@/events/auth";
import { parseEventsConfig } from "@/events/config";
import { EventsHub } from "@/events/hub";
import {
  ALICE,
  BOB,
  FakeSocket,
  FakeSubscriber,
  P1,
  WEB,
  defaultState,
  fakeAuth,
  flushPromises,
  headers,
  subscribe,
} from "./helpers";

vi.hoisted(() => {
  process.env.API_BASE_URL = "http://api.invalid";
  process.env.LIVE_SERVER_SECRET_KEY = "test-value";
});

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

type Gate = { cookie: string; resolve: () => void; reject: (status?: number) => void };

/** An auth api whose currentUser calls can be held open and then settled by the test. */
const gatedAuth = (hold: (cookie: string) => boolean) => {
  const base = fakeAuth(defaultState());
  const gates: Gate[] = [];
  const calls: string[] = [];
  const auth: EventsAuthApi = {
    projectRoles: base.projectRoles,
    currentUser(cookie) {
      calls.push(cookie);
      if (!hold(cookie)) return base.currentUser(cookie);
      return new Promise((resolve, reject) => {
        gates.push({
          cookie,
          resolve: () => void base.currentUser(cookie).then(resolve, reject),
          reject: (status = 401) => reject(Object.assign(new Error("auth"), { statusCode: status })),
        });
      });
    },
  };
  return { auth, gates, calls };
};

const hubWith = async (
  env: Record<string, string>,
  auth: EventsAuthApi = fakeAuth(defaultState()),
  log?: { warn: any }
) => {
  const config = parseEventsConfig({ LIVE_EVENTS_ENABLED: "1", WEB_URL: WEB, ...env });
  const hub = new EventsHub({ config, auth, createSubscriber: () => new FakeSubscriber(), log });
  await hub.start();
  return hub;
};

const open = async (hub: EventsHub, cookie: string, address?: string, extra: Record<string, string> = {}) => {
  const ws = new FakeSocket();
  const req: any = headers({ cookie, ...extra });
  if (address) req.socket = { remoteAddress: address };
  hub.handleConnection(ws, req);
  await flushPromises();
  return ws;
};

describe("config", () => {
  it("defaults and clamping below the upstream timeout", () => {
    const c = parseEventsConfig({});
    expect(c.maxPendingSockets).toBe(100);
    expect(c.maxSocketsPerAddress).toBe(25);
    expect(c.authTimeoutMs).toBe(8000);
    expect(c.authFailCacheMs).toBe(30_000);
    expect(c.trustedProxies).toEqual([]);
    expect(parseEventsConfig({ LIVE_EVENTS_AUTH_TIMEOUT_MS: "60000" }).authTimeoutMs).toBeLessThan(20_000);
  });
});

describe("first-message deadline", () => {
  it("a message sent before auth completes does not clear the deadline", async () => {
    const { auth, gates } = gatedAuth(() => true);
    const hub = await hubWith({ LIVE_EVENTS_AUTH_TIMEOUT_MS: "15000" }, auth);
    const ws = await open(hub, ALICE, "10.0.0.1");
    ws.say({ type: "subscribe", workspace_slug: "acme", project_ids: [P1] });
    await vi.advanceTimersByTimeAsync(9_999);
    expect(ws.closeCode).toBeNull();
    await vi.advanceTimersByTimeAsync(2);
    expect(ws.closeCode).toBe(4408);
    expect(gates).toHaveLength(1);
  });

  it("once auth succeeds after a message the deadline is cleared", async () => {
    const { auth, gates } = gatedAuth(() => true);
    const hub = await hubWith({}, auth);
    const ws = await open(hub, ALICE, "10.0.0.1");
    ws.say({ type: "subscribe", workspace_slug: "acme", project_ids: [P1] });
    await vi.advanceTimersByTimeAsync(2_000);
    gates[0].resolve();
    await flushPromises();
    await vi.advanceTimersByTimeAsync(30_000);
    expect(ws.closeCode).toBeNull();
    expect(ws.of("subscribed")).toHaveLength(1);
  });
});

describe("auth timeout", () => {
  it("a hung upstream frees the socket at the hub timeout", async () => {
    const { auth } = gatedAuth(() => true);
    const hub = await hubWith({ LIVE_EVENTS_AUTH_TIMEOUT_MS: "5000", LIVE_EVENTS_MAX_PENDING_SOCKETS: "2" }, auth);
    const a = await open(hub, "session-id=x1", "10.0.0.1");
    const b = await open(hub, "session-id=x2", "10.0.0.2");
    expect(hub.socketCount).toBe(2);
    const blocked = await open(hub, "session-id=x3", "10.0.0.3");
    expect(blocked.closeCode).toBe(4429);
    await vi.advanceTimersByTimeAsync(4_999);
    expect(a.closeCode).toBeNull();
    await vi.advanceTimersByTimeAsync(2);
    expect([a.closeCode, b.closeCode]).toEqual([4408, 4408]);
    expect(hub.socketCount).toBe(0);
    const again = await open(hub, "session-id=x4", "10.0.0.3");
    expect(again.closeCode).toBeNull(); // the pending slots are free again
  });

  it("a successful auth cancels the auth timeout", async () => {
    const hub = await hubWith({ LIVE_EVENTS_AUTH_TIMEOUT_MS: "3000" });
    const ws = await open(hub, ALICE, "10.0.0.1");
    ws.say({ type: "subscribe", workspace_slug: "acme", project_ids: [P1] });
    await vi.advanceTimersByTimeAsync(9_000);
    expect(ws.closeCode).toBeNull();
  });
});

describe("pending socket cap", () => {
  it("fake-cookie sockets cannot exhaust the cap for authenticated users", async () => {
    const { auth, gates } = gatedAuth((c) => c.startsWith("session-id=fake"));
    const hub = await hubWith({ LIVE_EVENTS_MAX_SOCKETS: "2", LIVE_EVENTS_MAX_PENDING_SOCKETS: "50" }, auth);
    const fakes: FakeSocket[] = [];
    // oxlint-disable-next-line no-await-in-loop
    for (let i = 0; i < 10; i++) fakes.push(await open(hub, `session-id=fake${i}`, `10.0.1.${i}`));
    expect(hub.socketCount).toBe(10); // all pending, more than maxSockets
    const alice = await open(hub, ALICE, "10.0.2.1");
    const bob = await open(hub, BOB, "10.0.2.2");
    expect([alice.closeCode, bob.closeCode]).toEqual([null, null]);
    await subscribe(alice, "acme", [P1]);
    expect(alice.of("subscribed")).toHaveLength(1);
    gates.forEach((g) => g.reject(401));
    await flushPromises();
    expect(fakes.every((f) => f.closeCode === 4401)).toBe(true);
    expect(hub.socketCount).toBe(2);
    // the authenticated budget itself is still enforced
    const third = await open(hub, ALICE, "10.0.2.3");
    expect(third.closeCode).toBe(4429);
  });

  it("refuses new sockets while the pending cap is reached", async () => {
    const { auth, gates } = gatedAuth(() => true);
    const hub = await hubWith({ LIVE_EVENTS_MAX_PENDING_SOCKETS: "3" }, auth);
    // oxlint-disable-next-line no-await-in-loop
    for (let i = 0; i < 3; i++) await open(hub, `session-id=p${i}`, `10.0.3.${i}`);
    const over = await open(hub, ALICE, "10.0.3.9");
    expect(over.closeCode).toBe(4429);
    gates[0].reject(401);
    await flushPromises();
    const ok = await open(hub, "session-id=p9", "10.0.3.9");
    expect(ok.closeCode).toBeNull();
  });
});

describe("per-address cap", () => {
  it("limits sockets per remote address and releases on close", async () => {
    const hub = await hubWith({ LIVE_EVENTS_MAX_SOCKETS_PER_ADDRESS: "2", LIVE_EVENTS_MAX_SOCKETS_PER_USER: "10" });
    const a = await open(hub, ALICE, "192.0.2.10");
    const b = await open(hub, ALICE, "192.0.2.10");
    const c = await open(hub, ALICE, "192.0.2.10");
    const other = await open(hub, ALICE, "192.0.2.11");
    expect([a.closeCode, b.closeCode, c.closeCode, other.closeCode]).toEqual([null, null, 4429, null]);
    a.close();
    const d = await open(hub, ALICE, "192.0.2.10");
    expect(d.closeCode).toBeNull();
  });

  it("ignores X-Forwarded-For unless the peer is a trusted proxy", async () => {
    const hub = await hubWith({ LIVE_EVENTS_MAX_SOCKETS_PER_ADDRESS: "1" });
    const a = await open(hub, ALICE, "192.0.2.10", { "x-forwarded-for": "198.51.100.1" });
    const b = await open(hub, ALICE, "192.0.2.10", { "x-forwarded-for": "198.51.100.2" });
    expect([a.closeCode, b.closeCode]).toEqual([null, 4429]);
  });

  it("behind a trusted proxy the forwarded client address is used", async () => {
    const hub = await hubWith({
      LIVE_EVENTS_MAX_SOCKETS_PER_ADDRESS: "1",
      LIVE_EVENTS_TRUSTED_PROXIES: "172.16.0.0/12",
    });
    const a = await open(hub, ALICE, "172.16.0.5", { "x-forwarded-for": "198.51.100.1" });
    const b = await open(hub, ALICE, "172.16.0.5", { "x-forwarded-for": "198.51.100.2" });
    const c = await open(hub, ALICE, "172.16.0.5", { "x-forwarded-for": "198.51.100.1" });
    expect([a.closeCode, b.closeCode, c.closeCode]).toEqual([null, null, 4429]);
  });

  it("resolveClientAddress: rightmost untrusted hop, spoofed left entries ignored", () => {
    const { list, invalid } = buildTrustedProxies(["10.0.0.0/8", "bogus", "2001:db8::/200"]);
    expect(invalid).toBe(2);
    expect(resolveClientAddress("10.1.1.1", "6.6.6.6, 203.0.113.7, 10.2.2.2", list)).toBe("203.0.113.7");
    expect(resolveClientAddress("203.0.113.9", "6.6.6.6", list)).toBe("203.0.113.9");
    expect(resolveClientAddress("::ffff:10.1.1.1", "203.0.113.7", list)).toBe("203.0.113.7");
    expect(resolveClientAddress("10.1.1.1", "not-an-ip", list)).toBe("10.1.1.1");
    expect(resolveClientAddress("10.1.1.1", undefined, list)).toBe("10.1.1.1");
    expect(resolveClientAddress(undefined, "1.2.3.4", list)).toBeNull();
  });
});

describe("private peer without trusted proxies", () => {
  const manyUsers = (n: number) => {
    const state = defaultState();
    for (let i = 0; i < n; i++) state.users[`session-id=u${i}`] = { id: `user-${i}` };
    return fakeAuth(state);
  };

  it("stock config, private peer: more than 25 sockets from different users are all accepted", async () => {
    const warn = vi.fn();
    const hub = await hubWith({}, manyUsers(40), { warn });
    const sockets: FakeSocket[] = [];
    for (let i = 0; i < 40; i++) {
      // oxlint-disable-next-line no-await-in-loop
      sockets.push(await open(hub, `session-id=u${i}`, "10.1.2.3", { "x-forwarded-for": `198.51.100.${i + 1}` }));
    }
    expect(sockets.every((s) => s.closeCode === null)).toBe(true);
    expect(hub.socketCount).toBe(40);
    const notices = warn.mock.calls.filter((c) => String(c[0]).includes("LIVE_EVENTS_TRUSTED_PROXIES"));
    expect(notices).toHaveLength(1);
  });

  it("is still bound by the other caps", async () => {
    const hub = await hubWith({ LIVE_EVENTS_MAX_SOCKETS: "30" }, manyUsers(40));
    const sockets: FakeSocket[] = [];
    for (let i = 0; i < 32; i++) {
      // oxlint-disable-next-line no-await-in-loop
      sockets.push(await open(hub, `session-id=u${i}`, "127.0.0.1"));
    }
    expect(sockets.filter((s) => s.closeCode === 4429)).toHaveLength(2);
  });

  it("a public peer keeps the per-address cap with the stock config", async () => {
    const hub = await hubWith({}, manyUsers(40));
    const sockets: FakeSocket[] = [];
    for (let i = 0; i < 27; i++) {
      // oxlint-disable-next-line no-await-in-loop
      sockets.push(await open(hub, `session-id=u${i}`, "203.0.113.5"));
    }
    expect(sockets.filter((s) => s.closeCode === 4429)).toHaveLength(2);
  });

  it("other private families are covered", () => {
    for (const a of [
      "127.0.0.1",
      "10.9.9.9",
      "172.31.0.1",
      "192.168.1.1",
      "169.254.1.1",
      "::1",
      "fe80::1",
      "fd00::1",
      "::ffff:10.0.0.1",
    ]) {
      expect(isPrivateAddress(a)).toBe(true);
    }
    for (const a of ["203.0.113.5", "172.32.0.1", "2001:db8::1", "bogus"]) expect(isPrivateAddress(a)).toBe(false);
  });
});

describe("trusted proxy entries", () => {
  it("rejects an empty or non-numeric prefix", () => {
    const { list, invalid, valid } = buildTrustedProxies([
      "10.0.0.1/",
      "10.0.0.1/ 8",
      "10.0.0.1/-1",
      "10.0.0.1/8x",
      "10.0.0.1/33",
      "10.0.0.2",
    ]);
    expect(invalid).toBe(5);
    expect(valid).toBe(1);
    expect(list.check("203.0.113.9", "ipv4")).toBe(false);
  });
});

describe("upstream lookup abort", () => {
  it("is aborted when the hub auth timeout fires and when the socket goes away", async () => {
    const signals: AbortSignal[] = [];
    const auth: EventsAuthApi = {
      projectRoles: fakeAuth(defaultState()).projectRoles,
      currentUser: (_c, signal) => (signals.push(signal as AbortSignal), new Promise(() => undefined)),
    };
    const hub = await hubWith({ LIVE_EVENTS_AUTH_TIMEOUT_MS: "3000" }, auth);
    const a = await open(hub, "session-id=a", "203.0.113.1");
    const b = await open(hub, "session-id=b", "203.0.113.2");
    b.close();
    expect(signals[1].aborted).toBe(true);
    expect(signals[0].aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(3_001);
    expect(a.closeCode).toBe(4408);
    expect(signals[0].aborted).toBe(true);
  });
});

describe("failed cookie cache", () => {
  it("caches 401 only, not 403", async () => {
    const state = defaultState();
    state.users["session-id=gate"] = { status: 403 };
    const calls: string[] = [];
    const base = fakeAuth(state);
    const auth: EventsAuthApi = {
      projectRoles: base.projectRoles,
      currentUser: (c) => (calls.push(c), base.currentUser(c)),
    };
    const hub = await hubWith({}, auth);
    await open(hub, "session-id=gate", "203.0.113.3");
    await open(hub, "session-id=gate", "203.0.113.3");
    expect(calls).toHaveLength(2);
  });

  it("refuses a repeat without an upstream call, then expires", async () => {
    const { auth, calls } = gatedAuth(() => false);
    const hub = await hubWith({ LIVE_EVENTS_AUTH_FAIL_CACHE_MS: "5000" }, auth);
    const first = await open(hub, "session-id=nobody", "10.0.4.1");
    expect(first.closeCode).toBe(4401);
    expect(calls).toHaveLength(1);
    const second = await open(hub, "session-id=nobody", "10.0.4.1");
    expect(second.closeCode).toBe(4401);
    expect(calls).toHaveLength(1); // served from the cache
    await vi.advanceTimersByTimeAsync(5_001);
    const third = await open(hub, "session-id=nobody", "10.0.4.1");
    expect(third.closeCode).toBe(4401);
    expect(calls).toHaveLength(2); // expired: asked upstream again
  });

  it("does not cache transient upstream failures", async () => {
    const state = defaultState();
    state.users["session-id=flaky"] = { status: 503 };
    const calls: string[] = [];
    const base = fakeAuth(state);
    const auth: EventsAuthApi = {
      projectRoles: base.projectRoles,
      currentUser: (c) => (calls.push(c), base.currentUser(c)),
    };
    const hub = await hubWith({}, auth);
    await open(hub, "session-id=flaky", "10.0.4.2");
    await open(hub, "session-id=flaky", "10.0.4.2");
    expect(calls).toHaveLength(2);
  });

  it("never keeps the raw cookie", async () => {
    const hub = await hubWith({});
    await open(hub, "session-id=nobody-secret-value", "10.0.4.3");
    const dump = JSON.stringify([...(hub as any).failedCookies.keys()]);
    expect(dump).not.toContain("nobody-secret-value");
    expect((hub as any).failedCookies.size).toBe(1);
  });

  it("a cache time of 0 disables it", async () => {
    const { auth, calls } = gatedAuth(() => false);
    const hub = await hubWith({ LIVE_EVENTS_AUTH_FAIL_CACHE_MS: "0" }, auth);
    await open(hub, "session-id=nobody", "10.0.4.4");
    await open(hub, "session-id=nobody", "10.0.4.4");
    expect(calls).toHaveLength(2);
  });
});

describe("auth failure logging", () => {
  it("warns at most once per minute with a running count and no cookie", async () => {
    const warn = vi.fn();
    const hub = await hubWith({ LIVE_EVENTS_AUTH_FAIL_CACHE_MS: "0" }, undefined, { warn });
    // the payload-cap notice (FakeSocket has no ws receiver) is unrelated to this test
    const failureWarns = () => warn.mock.calls.filter((c) => String(c[0]).includes("authentication failures"));
    // oxlint-disable-next-line no-await-in-loop
    for (let i = 0; i < 20; i++) await open(hub, `session-id=bad${i}`, `10.0.5.${i}`);
    expect(failureWarns()).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(61_000);
    await open(hub, "session-id=bad99", "10.0.5.99");
    expect(failureWarns()).toHaveLength(2);
    expect(String(failureWarns()[1][0])).toContain("21");
    expect(JSON.stringify(warn.mock.calls)).not.toContain("bad99");
  });
});
