/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { extractSessionCookie } from "@/events/auth";
import { parseEventsConfig } from "@/events/config";
import { EventsHub } from "@/events/hub";
import {
  ACTOR,
  ALICE,
  BOB,
  FakeSocket,
  I1,
  I2,
  P1,
  P2,
  P3,
  connect,
  defaultState,
  evt,
  flushPromises,
  headers,
  makeHub,
  subscribe,
} from "./helpers";

vi.hoisted(() => {
  // the live env module validates these at import time
  process.env.API_BASE_URL = "http://api.invalid";
  process.env.LIVE_SERVER_SECRET_KEY = "test-value";
});

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

const started = async (env: Record<string, string> = {}, state = defaultState()) => {
  const ctx = makeHub(env, state);
  await ctx.hub.start();
  return ctx;
};

// Advance time in 25 s steps, answering pings so the heartbeat keeps the sockets alive.
const advanceAlive = async (sockets: FakeSocket[], ms: number) => {
  for (let t = 0; t < ms; t += 25_000) {
    // oxlint-disable-next-line no-await-in-loop
    await vi.advanceTimersByTimeAsync(Math.min(25_000, ms - t));
    sockets.forEach((s) => s.emit("pong"));
  }
};

describe("config and flag", () => {
  it("defaults", () => {
    const c = parseEventsConfig({});
    expect(c.enabled).toBe(false);
    expect(c.settleMs).toBe(2000);
    expect(c.projectRatePerSec).toBe(50);
    expect(c.maxSockets).toBe(500);
  });

  it("flag off: 4404 and no subscriber is created", async () => {
    const createSubscriber = vi.fn();
    const hub = new EventsHub({
      config: parseEventsConfig({}),
      auth: { currentUser: vi.fn(), projectRoles: vi.fn() },
      createSubscriber,
    });
    await hub.start();
    const ws = new FakeSocket();
    hub.handleConnection(ws, headers());
    expect(ws.closeCode).toBe(4404);
    expect(createSubscriber).not.toHaveBeenCalled();
  });
});

describe("handshake", () => {
  it("subscribes once to the pattern", async () => {
    const { sub } = await started();
    expect(sub.patterns).toEqual(["plane:live-events:*"]);
  });

  it("extracts only the session-id cookie", () => {
    expect(extractSessionCookie("a=1; session-id=abc; csrftoken=x")).toBe("session-id=abc");
    expect(extractSessionCookie("a=1")).toBeNull();
    expect(extractSessionCookie(undefined)).toBeNull();
  });

  it("missing cookie closes 4401", async () => {
    const { hub } = await started();
    const ws = new FakeSocket();
    hub.handleConnection(ws, headers({ cookie: "a=1" }));
    expect(ws.closeCode).toBe(4401);
  });

  it("unknown session closes 4401", async () => {
    const { hub } = await started();
    const ws = await connect(hub, "session-id=nobody");
    expect(ws.closeCode).toBe(4401);
  });

  it("bad origin closes 4403", async () => {
    const { hub } = await started();
    const ws = new FakeSocket();
    hub.handleConnection(ws, headers({ origin: "https://evil.example.net" }));
    expect(ws.closeCode).toBe(4403);
  });

  it("no first message within 10 s closes the socket", async () => {
    const { hub } = await started();
    const ws = await connect(hub);
    vi.advanceTimersByTime(9_999);
    expect(ws.closeCode).toBeNull();
    vi.advanceTimersByTime(2);
    expect(ws.closeCode).toBe(4408);
  });

  it("the deadline is cleared by the first message", async () => {
    const { hub } = await started();
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    vi.advanceTimersByTime(9_000);
    expect(ws.closeCode).toBeNull();
    vi.advanceTimersByTime(2_000);
    expect(ws.closeCode).toBeNull();
  });
});

describe("membership", () => {
  it("grants member projects and denies others, including guest roles", async () => {
    const { hub } = await started();
    const ws = await connect(hub, BOB);
    await subscribe(ws, "acme", [P1, P3, P2]); // P1 guest (5), P2 not a member
    expect(ws.of("subscribed")[0]).toEqual({ type: "subscribed", project_ids: [P3], denied: [P1, P2] });
  });

  it("cross-workspace slug: projects of another workspace are denied", async () => {
    const { hub } = await started();
    const ws = await connect(hub, ALICE);
    await subscribe(ws, "acme", [P3]);
    expect(ws.of("subscribed")[0].project_ids).toEqual([]);
    await subscribe(ws, "other", [P3]);
    expect(ws.of("subscribed")[1].project_ids).toEqual([P3]);
  });

  it("unknown workspace grants nothing", async () => {
    const { hub } = await started();
    const ws = await connect(hub);
    await subscribe(ws, "nowhere", [P1]);
    expect(ws).toBeDefined();
    expect(ws.closeCode).toBe(4401); // roles endpoint rejected the session for that workspace
  });

  it("member of A subscribing to B receives nothing from B", async () => {
    const { hub, sub } = await started();
    const ws = await connect(hub, ALICE);
    await subscribe(ws, "acme", [P1, P3]);
    sub.publish(P3, evt(P3, [I1]));
    vi.advanceTimersByTime(300);
    expect(ws.of("events")).toEqual([]);
  });

  it("unsubscribe stops delivery", async () => {
    const { hub, sub } = await started();
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    ws.say({ type: "unsubscribe", project_ids: [P1] });
    await flushPromises();
    sub.publish(P1, evt(P1, [I1]));
    vi.advanceTimersByTime(300);
    expect(ws.of("events")).toEqual([]);
  });

  it("revalidation drops revoked projects and closes 4401 when the session is gone", async () => {
    const state = defaultState();
    const { hub, sub, auth } = await started({}, state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1, P2]);
    delete state.roles.acme[ALICE][P2];
    state.roles.acme[ALICE][P1] = 5; // demoted to guest
    await advanceAlive([ws], 5 * 60_000);
    expect(ws.of("revoked")[0].project_ids.toSorted()).toEqual([P1, P2].toSorted());
    sub.publish(P1, evt(P1, [I1]));
    vi.advanceTimersByTime(300);
    expect(ws.of("events")).toEqual([]);
    delete auth.state.users[ALICE];
    await advanceAlive([ws], 5 * 60_000);
    expect(ws.closeCode).toBe(4401);
  });

  it("a transient auth failure at revalidation keeps the socket", async () => {
    const state = defaultState();
    const { hub } = await started({}, state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.users[ALICE] = { status: 502 } as any;
    await advanceAlive([ws], 5 * 60_000);
    expect(ws.closeCode).toBeNull();
  });
});

describe("fan-out", () => {
  it("isolates projects and coalesces per issue within 250 ms", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub, ALICE);
    const b = await connect(hub, BOB);
    await subscribe(a, "acme", [P1, P2]);
    await subscribe(b, "acme", [P3]);
    sub.publish(P1, evt(P1, [I1]));
    sub.publish(P1, evt(P1, [I1, I2], { kind: "comment", verb: "created" }));
    sub.publish(P3, evt(P3, [I2]));
    vi.advanceTimersByTime(249);
    expect(a.of("events")).toEqual([]);
    vi.advanceTimersByTime(2);
    const frames = a.of("events");
    expect(frames).toHaveLength(1);
    expect(frames[0].project_id).toBe(P1);
    const item = frames[0].items.find((i: any) => i.issue_id === I1);
    expect(item.kinds.toSorted()).toEqual(["comment", "issue"]);
    expect(item.verbs.toSorted()).toEqual(["created", "updated"]);
    expect(item.actor_ids).toEqual([ACTOR]);
    expect(frames[0].items).toHaveLength(2);
    expect(frames[0].full_refresh).toBeUndefined();
    expect(b.of("events").map((f) => f.project_id)).toEqual([P3]);
  });

  it("issue_ids '*' becomes one full_refresh frame", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    sub.publish(P1, evt(P1, "*"));
    sub.publish(P1, evt(P1, [I1]));
    vi.advanceTimersByTime(300);
    expect(a.of("events")).toEqual([{ type: "events", project_id: P1, items: [], full_refresh: true }]);
  });

  it("rate-limit overflow yields one full_refresh frame and nothing is dropped", async () => {
    const { hub, sub } = await started({ LIVE_EVENTS_PROJECT_RATE_PER_SEC: "5" });
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    const ids = Array.from({ length: 20 }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`);
    ids.forEach((id) => sub.publish(P1, evt(P1, [id])));
    vi.advanceTimersByTime(300);
    const frames = a.of("events");
    expect(frames).toHaveLength(1);
    expect(frames[0].full_refresh).toBe(true);
    expect(frames[0].items).toEqual([]);
    expect(hub.invalidDropped).toBe(0);
  });

  it("at or under the limit sends per-issue items, and the limit is per project", async () => {
    const { hub, sub } = await started({ LIVE_EVENTS_PROJECT_RATE_PER_SEC: "5" });
    const a = await connect(hub);
    await subscribe(a, "acme", [P1, P2]);
    for (let i = 0; i < 5; i++) sub.publish(P1, evt(P1, [I1]));
    for (let i = 0; i < 20; i++) sub.publish(P2, evt(P2, [I2]));
    vi.advanceTimersByTime(300);
    const byProject = Object.fromEntries(a.of("events").map((f) => [f.project_id, f]));
    expect(byProject[P1].full_refresh).toBeUndefined();
    expect(byProject[P1].items).toHaveLength(1);
    expect(byProject[P2].full_refresh).toBe(true);
  });

  it("more than 500 distinct ids in a window escalates to full_refresh", async () => {
    const { hub, sub } = await started({ LIVE_EVENTS_PROJECT_RATE_PER_SEC: "1000" });
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    for (let n = 0; n < 2; n++) {
      const ids = Array.from(
        { length: 300 },
        (_, i) => `00000000-0000-4000-8000-${String(n * 300 + i).padStart(12, "0")}`
      );
      sub.publish(P1, evt(P1, ids));
    }
    vi.advanceTimersByTime(300);
    expect(a.of("events")[0].full_refresh).toBe(true);
  });

  it("settle events are re-emitted once after LIVE_EVENTS_SETTLE_MS", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    sub.publish(P1, evt(P1, [I1], { kind: "cycle", verb: "deleted", settle: true }));
    vi.advanceTimersByTime(300);
    expect(a.of("events")).toHaveLength(1);
    vi.advanceTimersByTime(1_600); // t = 1900 ms
    expect(a.of("events")).toHaveLength(1);
    vi.advanceTimersByTime(200); // settle fires at 2000 ms, flushed 250 ms later
    expect(a.of("events")).toHaveLength(1);
    vi.advanceTimersByTime(200);
    expect(a.of("events")).toHaveLength(2);
    vi.advanceTimersByTime(10_000);
    expect(a.of("events")).toHaveLength(2);
  });

  it("respects a custom settle delay", async () => {
    const { hub, sub } = await started({ LIVE_EVENTS_SETTLE_MS: "500" });
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    sub.publish(P1, evt(P1, [I1], { settle: true }));
    vi.advanceTimersByTime(300);
    vi.advanceTimersByTime(600); // settle at 500 ms, flushed at 750 ms
    expect(a.of("events")).toHaveLength(2);
  });

  it("drops and counts invalid redis messages", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    sub.publish(P1, "not json");
    sub.publish(P1, { ...evt(P1, [I1]), v: 2 });
    sub.publish(P1, { ...evt(P1, ["nope"]) });
    sub.publish(P1, { ...evt(P1, [I1]), kind: "bogus" });
    sub.publish(P1, { ...evt(P1, [I1]), verb: "bogus" });
    sub.publish(
      P1,
      evt(
        P1,
        Array.from({ length: 501 }, () => I1)
      )
    );
    sub.publish(P1, evt(P2, [I1])); // channel and payload disagree
    vi.advanceTimersByTime(300);
    expect(a.of("events")).toEqual([]);
    expect(hub.invalidDropped).toBe(7);
    sub.publish(P1, evt(P1, [I1]));
    vi.advanceTimersByTime(300);
    expect(a.of("events")).toHaveLength(1);
  });
});

describe("limits", () => {
  it("total socket limit", async () => {
    const { hub } = await started({ LIVE_EVENTS_MAX_SOCKETS: "2", LIVE_EVENTS_MAX_SOCKETS_PER_USER: "5" });
    await connect(hub, ALICE);
    await connect(hub, BOB);
    const third = await connect(hub, ALICE);
    expect(third.closeCode).toBe(4429);
  });

  it("per-user socket limit", async () => {
    const { hub } = await started({ LIVE_EVENTS_MAX_SOCKETS_PER_USER: "2" });
    const a1 = await connect(hub, ALICE);
    const a2 = await connect(hub, ALICE);
    const a3 = await connect(hub, ALICE);
    const b1 = await connect(hub, BOB);
    expect([a1.closeCode, a2.closeCode, a3.closeCode, b1.closeCode]).toEqual([null, null, 4429, null]);
  });

  it("projects per socket", async () => {
    const { hub } = await started({ LIVE_EVENTS_MAX_PROJECTS_PER_SOCKET: "2" });
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1, P2]);
    expect(ws.closeCode).toBeNull();
    await subscribe(ws, "other", [P3]);
    expect(ws.closeCode).toBe(4429);
  });

  it("inbound message larger than 4 KB", async () => {
    const { hub } = await started();
    const ws = await connect(hub);
    ws.say(" ".repeat(4097));
    expect(ws.closeCode).toBe(4413);
  });

  it("more than 5 inbound messages per second", async () => {
    const { hub } = await started();
    const ws = await connect(hub);
    for (let i = 0; i < 5; i++) ws.say({ type: "pong" });
    expect(ws.closeCode).toBeNull();
    ws.say({ type: "pong" });
    expect(ws.closeCode).toBe(4429);
  });

  it("invalid client messages close 4400", async () => {
    const { hub } = await started();
    const bads = [
      "{",
      JSON.stringify({ type: "nope" }),
      JSON.stringify({ type: "subscribe", workspace_slug: "acme", project_ids: ["x"] }),
    ];
    for (const bad of bads) {
      // oxlint-disable-next-line no-await-in-loop
      const ws = await connect(hub);
      ws.say(bad);
      expect(ws.closeCode).toBe(4400);
    }
    const ws = await connect(hub);
    await subscribe(ws, "../../etc", [P1]);
    expect(ws.closeCode).toBe(4400);
  });

  it("a client supplied userId is ignored", async () => {
    const { hub } = await started();
    const ws = await connect(hub, ALICE);
    ws.say({ type: "subscribe", workspace_slug: "acme", project_ids: [P3], userId: "u-bob" });
    await flushPromises();
    expect(ws.of("subscribed")[0].project_ids).toEqual([]);
  });

  it("backpressure: bufferedAmount over 256 KB closes the socket", async () => {
    const { hub, sub } = await started();
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    ws.bufferedAmount = 256 * 1024 + 1;
    sub.publish(P1, evt(P1, [I1]));
    vi.advanceTimersByTime(300);
    expect(ws.closeCode).toBe(4429);
    expect(ws.of("events")).toEqual([]);
  });
});

describe("heartbeat and resync", () => {
  it("pings every 25 s and terminates after 2 missed pongs", async () => {
    const { hub } = await started();
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    vi.advanceTimersByTime(25_000);
    expect(ws.pings).toBe(1);
    expect(ws.of("ping")).toHaveLength(1);
    ws.emit("pong");
    vi.advanceTimersByTime(25_000);
    expect(ws.terminated).toBe(false);
    ws.say({ type: "pong" }); // app-level pong also counts
    vi.advanceTimersByTime(25_000);
    expect(ws.terminated).toBe(false);
    vi.advanceTimersByTime(25_000 * 3);
    expect(ws.terminated).toBe(true);
    expect(hub.socketCount).toBe(0);
  });

  it("sends resync to every socket when the subscriber reconnects, not on first connect", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub, ALICE);
    const b = await connect(hub, BOB);
    sub.emit("ready");
    expect(a.of("resync")).toHaveLength(0);
    sub.emit("ready");
    expect(a.of("resync")).toHaveLength(1);
    expect(b.of("resync")).toHaveLength(1);
  });
});

describe("publisher contract", () => {
  it("accepts the API payload shape that names the id list `ids`", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    const wire = { v: 1, project_id: P1, kind: "issue", verb: "created", ids: [I1], actor_id: ACTOR, settle: false };
    sub.publish(P1, wire);
    sub.publish(P1, { ...wire, ids: "*" });
    vi.advanceTimersByTime(300);
    expect(hub.invalidDropped).toBe(0);
    expect(a.of("events")).toHaveLength(1);
    expect(a.of("events")[0].full_refresh).toBe(true);
  });

  it("accepts a null actor_id and a missing ts", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    sub.publish(P1, { v: 1, project_id: P1, kind: "comment", verb: "updated", ids: [I1], actor_id: null });
    vi.advanceTimersByTime(300);
    expect(a.of("events")[0].items[0].issue_id).toBe(I1);
  });
});

describe("settle timers are bounded per project", () => {
  it("a burst of settle events collapses into one project-wide re-emit after the cap", async () => {
    const { hub, sub } = await started();
    const a = await connect(hub);
    await subscribe(a, "acme", [P1]);
    // 30 events spread over separate rate windows so the rate limit does not interfere
    for (let i = 0; i < 30; i++) {
      sub.publish(P1, evt(P1, [I1], { settle: true }));
      vi.advanceTimersByTime(20);
    }
    const before = a.of("events").length;
    vi.advanceTimersByTime(5_000);
    const after = a.of("events");
    expect(after.length).toBeGreaterThan(before);
    expect(after.some((f) => f.full_refresh === true)).toBe(true);
    vi.advanceTimersByTime(10_000);
    expect(a.of("events")).toHaveLength(after.length);
  });
});
