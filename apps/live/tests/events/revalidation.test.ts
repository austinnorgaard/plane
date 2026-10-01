/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { parseEventsConfig } from "@/events/config";
import { ALICE, I1, P1, P2, connect, defaultState, evt, makeHub, subscribe } from "./helpers";

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

const MID = () => 0.5; // no jitter: exactly the configured interval
const INTERVAL = 60_000;

const started = async (state = defaultState(), env: Record<string, string> = {}, random: () => number = MID) => {
  const ctx = makeHub(env, state, undefined, random);
  await ctx.hub.start();
  return ctx;
};

/** Advance one revalidation interval, answering pings in between so the heartbeat does not interfere. */
const cycle = async (sockets: { emit: (e: string) => unknown }[], ms = INTERVAL) => {
  for (let t = 0; t < ms; t += 20_000) {
    // oxlint-disable-next-line no-await-in-loop
    await vi.advanceTimersByTimeAsync(Math.min(20_000, ms - t));
    sockets.forEach((s) => s.emit("pong"));
  }
};

describe("revalidation config", () => {
  it("defaults to 60 s, 3 failures", () => {
    const c = parseEventsConfig({});
    expect(c.revalidateMs).toBe(60_000);
    expect(c.revalidateMaxFailures).toBe(3);
  });

  it("reads LIVE_EVENTS_REVALIDATE_MS and LIVE_EVENTS_REVALIDATE_MAX_FAILURES", () => {
    const c = parseEventsConfig({ LIVE_EVENTS_REVALIDATE_MS: "30000", LIVE_EVENTS_REVALIDATE_MAX_FAILURES: "5" });
    expect(c.revalidateMs).toBe(30_000);
    expect(c.revalidateMaxFailures).toBe(5);
  });
});

describe("revalidation of live event grants", () => {
  it("does not revalidate before the interval and does after it", async () => {
    const { hub, auth } = await started();
    const spy = vi.spyOn(auth, "currentUser");
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    spy.mockClear();
    await cycle([ws], INTERVAL - 1000);
    expect(spy).not.toHaveBeenCalled();
    await cycle([ws], 1500);
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("revoke: a removed membership drops that project at the next revalidation and keeps the others", async () => {
    const state = defaultState();
    const { hub, sub } = await started(state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1, P2]);
    delete state.roles.acme[ALICE][P1];
    await cycle([ws]);
    expect(ws.closeCode).toBeNull();
    expect(ws.of("revoked")).toEqual([{ type: "revoked", project_ids: [P1] }]);
    sub.publish(P1, evt(P1, [I1]));
    sub.publish(P2, evt(P2, [I1]));
    await vi.advanceTimersByTimeAsync(300);
    const delivered = ws.of("events").flatMap((f) => (f.project_id ? [f.project_id] : []));
    expect(delivered).toContain(P2);
    expect(delivered).not.toContain(P1);
  });

  it("logout: a session that no longer resolves closes 4401 at the next revalidation", async () => {
    const state = defaultState();
    const { hub } = await started(state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.users[ALICE] = { status: 401 } as any;
    await cycle([ws]);
    expect(ws.closeCode).toBe(4401);
  });

  it("deactivation: a user the API now refuses (403) closes 4401 at the next revalidation", async () => {
    const state = defaultState();
    const { hub } = await started(state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.users[ALICE] = { status: 403 } as any;
    await cycle([ws]);
    expect(ws.closeCode).toBe(4401);
  });

  it("closes with 1013 after N consecutive transient failures, not before", async () => {
    const state = defaultState();
    const { hub } = await started(state, { LIVE_EVENTS_REVALIDATE_MAX_FAILURES: "3" });
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.rolesError = { acme: 503 };
    await cycle([ws]);
    expect(ws.closeCode).toBeNull();
    await cycle([ws]);
    expect(ws.closeCode).toBeNull();
    await cycle([ws]);
    expect(ws.closeCode).toBe(1013);
    expect(hub.socketCount).toBe(0);
  });

  it("counts transient failures of the session check too", async () => {
    const state = defaultState();
    const { hub } = await started(state, { LIVE_EVENTS_REVALIDATE_MAX_FAILURES: "2" });
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.users[ALICE] = { status: 502 } as any;
    await cycle([ws]);
    expect(ws.closeCode).toBeNull();
    await cycle([ws]);
    expect(ws.closeCode).toBe(1013);
  });

  it("one transient failure followed by success does not close, and the counter resets", async () => {
    const state = defaultState();
    const { hub } = await started(state, { LIVE_EVENTS_REVALIDATE_MAX_FAILURES: "3" });
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.rolesError = { acme: 503 };
    await cycle([ws]);
    delete state.rolesError;
    await cycle([ws]);
    expect(ws.closeCode).toBeNull();
    // two more failures are below N because the earlier success reset the count
    state.rolesError = { acme: 503 };
    await cycle([ws]);
    await cycle([ws]);
    expect(ws.closeCode).toBeNull();
    await cycle([ws]);
    expect(ws.closeCode).toBe(1013);
  });

  it("jitter stays within +/-20% of the interval", () => {
    const { hub: lo } = makeHub({}, defaultState(), undefined, () => 0);
    const { hub: hi } = makeHub({}, defaultState(), undefined, () => 0.999999);
    const { hub: mid } = makeHub({}, defaultState(), undefined, () => 0.5);
    expect(lo.nextRevalidateDelay()).toBe(48_000);
    expect(hi.nextRevalidateDelay()).toBeGreaterThanOrEqual(71_990);
    expect(hi.nextRevalidateDelay()).toBeLessThanOrEqual(72_000);
    expect(mid.nextRevalidateDelay()).toBe(60_000);
    const { hub } = makeHub({ LIVE_EVENTS_REVALIDATE_MS: "10000" }, defaultState());
    for (let i = 0; i < 500; i++) {
      const d = hub.nextRevalidateDelay();
      expect(d).toBeGreaterThanOrEqual(8000);
      expect(d).toBeLessThanOrEqual(12_000);
    }
  });

  it("sockets use different delays when the random source differs (no lockstep)", async () => {
    const seq = [0.0, 0.25, 0.75, 1];
    let i = 0;
    const state = defaultState();
    const { hub, auth } = await started(state, {}, () => seq[i++ % seq.length] ?? 0.5);
    const spy = vi.spyOn(auth, "currentUser");
    const a = await connect(hub);
    const b = await connect(hub, ALICE);
    await subscribe(a, "acme", [P1]);
    await subscribe(b, "acme", [P1]);
    spy.mockClear();
    await cycle([a, b], 49_000); // only the earliest socket (delay 48 s) has fired
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("leaves no timer behind when a socket closes", async () => {
    const { hub } = await started();
    const baseline = vi.getTimerCount();
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    expect(vi.getTimerCount()).toBeGreaterThan(baseline);
    ws.close(1000);
    expect(vi.getTimerCount()).toBe(baseline);
  });

  it("stops the timer when the socket closes", async () => {
    const { hub, auth } = await started();
    const spy = vi.spyOn(auth, "currentUser");
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    ws.close(1000);
    spy.mockClear();
    await cycle([], INTERVAL * 3);
    expect(spy).not.toHaveBeenCalled();
  });

  it("closing a socket aborts an in-flight revalidation call and starts no new timer", async () => {
    const state = defaultState();
    const { hub, auth } = await started(state);
    let signal: AbortSignal | undefined;
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    vi.spyOn(auth, "currentUser").mockImplementation(((_cookie: string, s?: AbortSignal) => {
      signal = s;
      return new Promise(() => undefined);
    }) as any);
    await cycle([ws], INTERVAL + 1000);
    expect(signal).toBeDefined();
    expect(signal?.aborted).toBe(false);
    ws.close(1000);
    expect(signal?.aborted).toBe(true);
    expect(vi.getTimerCount()).toBeLessThanOrEqual(1); // only the hub heartbeat remains
  });
});
