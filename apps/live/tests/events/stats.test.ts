/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import type { Server } from "http";
import type { AddressInfo } from "net";
import express from "express";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerController } from "@plane/decorators";
import { HealthController } from "@/controllers/health.controller";
import { registerStatsSource } from "@/events/stats";
import {
  ALICE,
  BOB,
  FakeSocket,
  I1,
  P1,
  connect,
  defaultState,
  evt,
  flushPromises,
  headers,
  makeHub,
  subscribe,
} from "./helpers";

vi.hoisted(() => {
  process.env.API_BASE_URL = "http://api.invalid";
  process.env.LIVE_SERVER_SECRET_KEY = "test-secret-key-0123456789";
});

const SECRET = "test-secret-key-0123456789";

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
  registerStatsSource(null);
});

const started = async (env: Record<string, string> = {}, state = defaultState()) => {
  const ctx = makeHub(env, state, undefined, () => 0.5);
  await ctx.hub.start();
  return ctx;
};

const open = async (hub: any, cookie: string, address: string) => {
  const ws = new FakeSocket();
  hub.handleConnection(ws, { ...headers({ cookie }), socket: { remoteAddress: address } });
  await flushPromises();
  return ws;
};

describe("hub stats counters", () => {
  it("starts at zero", async () => {
    const { hub } = await started();
    expect(hub.stats()).toEqual({
      sockets: { open: 0, authenticated: 0, pending: 0 },
      accepted: 0,
      authenticated: 0,
      rejected: { pendingCap: 0, addressCap: 0, authFail: 0, authTimeout: 0, other: 0 },
      framesSent: 0,
      invalid: { redisDropped: 0, clientMessages: 0 },
      rateLimitOverflows: { inboundMessages: 0, projectEvents: 0 },
      revalidationCloses: { auth4401: 0, unavailable1013: 0 },
    });
  });

  it("open, authenticated, pending sockets and accepted totals", async () => {
    const { hub } = await started();
    const a = await connect(hub, ALICE);
    await connect(hub, BOB);
    expect(hub.stats().sockets).toEqual({ open: 2, authenticated: 2, pending: 0 });
    expect(hub.stats().accepted).toBe(2);
    expect(hub.stats().authenticated).toBe(2);
    a.close();
    expect(hub.stats().sockets.open).toBe(1);
    expect(hub.stats().accepted).toBe(2);
  });

  it("pending sockets are counted while authentication is unfinished", async () => {
    const state = defaultState();
    const { hub, auth } = await started({}, state);
    const releases: (() => void)[] = [];
    auth.currentUser = () => new Promise((resolve) => releases.push(() => resolve({ id: "u-alice" })));
    const ws = new FakeSocket();
    hub.handleConnection(ws, headers());
    await flushPromises();
    expect(hub.stats().sockets).toEqual({ open: 1, authenticated: 0, pending: 1 });
    releases.forEach((r) => r());
    await flushPromises();
    expect(hub.stats().sockets).toEqual({ open: 1, authenticated: 1, pending: 0 });
  });

  it("rejected: pending cap", async () => {
    const { hub, auth } = await started({ LIVE_EVENTS_MAX_PENDING_SOCKETS: "1" });
    auth.currentUser = () => new Promise(() => undefined);
    await open(hub, ALICE, "192.0.2.1");
    const blocked = await open(hub, ALICE, "192.0.2.2");
    expect(blocked.closeCode).toBe(4429);
    expect(hub.stats().rejected.pendingCap).toBe(1);
    expect(hub.stats().rejected.addressCap).toBe(0);
  });

  it("rejected: per-address cap", async () => {
    const { hub } = await started({ LIVE_EVENTS_MAX_SOCKETS_PER_ADDRESS: "1", LIVE_EVENTS_MAX_SOCKETS_PER_USER: "10" });
    await open(hub, ALICE, "192.0.2.1");
    const blocked = await open(hub, ALICE, "192.0.2.1");
    expect(blocked.closeCode).toBe(4429);
    expect(hub.stats().rejected.addressCap).toBe(1);
    expect(hub.stats().rejected.pendingCap).toBe(0);
  });

  it("rejected: auth failure (no cookie and refused session)", async () => {
    const { hub } = await started();
    const none = new FakeSocket();
    hub.handleConnection(none, { headers: { origin: "https://plane.example.com", host: "plane.example.com" } });
    expect(none.closeCode).toBe(4401);
    expect(hub.stats().rejected.authFail).toBe(1);
    const bad = await connect(hub, "session-id=nobody");
    expect(bad.closeCode).toBe(4401);
    expect(hub.stats().rejected.authFail).toBe(2);
    expect(hub.stats().rejected.authTimeout).toBe(0);
  });

  it("rejected: auth timeout", async () => {
    const { hub, auth } = await started({ LIVE_EVENTS_AUTH_TIMEOUT_MS: "5000" });
    auth.currentUser = () => new Promise(() => undefined);
    const ws = await connect(hub);
    await vi.advanceTimersByTimeAsync(5_001);
    expect(ws.closeCode).toBe(4408);
    expect(hub.stats().rejected.authTimeout).toBe(1);
    expect(hub.stats().rejected.authFail).toBe(0);
  });

  it("frames sent", async () => {
    const { hub, sub } = await started();
    const ws = await connect(hub);
    expect(hub.stats().framesSent).toBe(0);
    await subscribe(ws, "acme", [P1]);
    expect(hub.stats().framesSent).toBe(1); // subscribed
    sub.publish(P1, evt(P1, [I1]));
    await vi.advanceTimersByTimeAsync(300);
    expect(ws.of("events")).toHaveLength(1);
    expect(hub.stats().framesSent).toBe(2);
  });

  it("invalid messages: dropped Redis messages and bad client messages", async () => {
    const { hub, sub } = await started();
    const ws = await connect(hub);
    sub.publish(P1, "not json");
    sub.publish(P1, { v: 2 });
    expect(hub.stats().invalid.redisDropped).toBe(2);
    ws.say("not json");
    expect(ws.closeCode).toBe(4400);
    expect(hub.stats().invalid.clientMessages).toBe(1);
  });

  it("invalid messages: a binary client frame", async () => {
    const { hub } = await started();
    const ws = await connect(hub);
    ws.emit("message", Buffer.from("{}"), true);
    expect(ws.closeCode).toBe(4400);
    expect(hub.stats().invalid.clientMessages).toBe(1);
  });

  it("rate-limit overflows: inbound message rate (4429) and project event rate (full refresh)", async () => {
    const { hub, sub } = await started({ LIVE_EVENTS_PROJECT_RATE_PER_SEC: "2" });
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    for (let i = 0; i < 6; i++) ws.say({ type: "pong" });
    expect(ws.closeCode).toBe(4429);
    expect(hub.stats().rateLimitOverflows.inboundMessages).toBe(1);
    expect(hub.stats().rateLimitOverflows.projectEvents).toBe(0);
    const other = await connect(hub, ALICE);
    await subscribe(other, "acme", [P1]);
    for (let i = 0; i < 5; i++) sub.publish(P1, evt(P1, [I1]));
    expect(hub.stats().rateLimitOverflows.projectEvents).toBe(3);
  });

  it("revalidation closes: 4401", async () => {
    const state = defaultState();
    const { hub } = await started({}, state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.users[ALICE] = { status: 401 } as any;
    for (let i = 0; i < 3; i++) {
      // oxlint-disable-next-line no-await-in-loop
      await vi.advanceTimersByTimeAsync(20_000);
      ws.emit("pong");
    }
    expect(ws.closeCode).toBe(4401);
    expect(hub.stats().revalidationCloses).toEqual({ auth4401: 1, unavailable1013: 0 });
  });

  it("revalidation closes: 4401 when the session now belongs to another user", async () => {
    const state = defaultState();
    const { hub } = await started({}, state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.users[ALICE] = { id: "u-someone-else" };
    for (let i = 0; i < 3; i++) {
      // oxlint-disable-next-line no-await-in-loop
      await vi.advanceTimersByTimeAsync(20_000);
      ws.emit("pong");
    }
    expect(ws.closeCode).toBe(4401);
    expect(hub.stats().revalidationCloses).toEqual({ auth4401: 1, unavailable1013: 0 });
  });

  it("revalidation closes: 4401 when the project roles call reports the session ended", async () => {
    const state = defaultState();
    const { hub } = await started({}, state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.rolesError = { acme: 401 };
    for (let i = 0; i < 3; i++) {
      // oxlint-disable-next-line no-await-in-loop
      await vi.advanceTimersByTimeAsync(20_000);
      ws.emit("pong");
    }
    expect(ws.closeCode).toBe(4401);
    expect(hub.stats().revalidationCloses).toEqual({ auth4401: 1, unavailable1013: 0 });
  });

  it("revalidation closes: 1013", async () => {
    const state = defaultState();
    const { hub } = await started({ LIVE_EVENTS_REVALIDATE_MAX_FAILURES: "1" }, state);
    const ws = await connect(hub);
    await subscribe(ws, "acme", [P1]);
    state.rolesError = { acme: 503 };
    for (let i = 0; i < 3; i++) {
      // oxlint-disable-next-line no-await-in-loop
      await vi.advanceTimersByTimeAsync(20_000);
      ws.emit("pong");
    }
    expect(ws.closeCode).toBe(1013);
    expect(hub.stats().revalidationCloses).toEqual({ auth4401: 0, unavailable1013: 1 });
  });

  it("the snapshot holds numbers only", async () => {
    const { hub } = await started();
    await connect(hub);
    const walk = (value: unknown): void => {
      if (value && typeof value === "object") Object.values(value).forEach(walk);
      else expect(typeof value).toBe("number");
    };
    walk(hub.stats());
  });
});

describe("counters endpoint", () => {
  vi.useRealTimers();

  const serve = async () => {
    const app = express();
    const router = express.Router();
    registerController(router, HealthController, []);
    app.use(router);
    const server: Server = await new Promise((resolve) => {
      const s = app.listen(0, "localhost", () => resolve(s));
    });
    const { address, port } = server.address() as AddressInfo;
    const base = `http://${address.includes(":") ? `[${address}]` : address}:${port}`;
    return { base, close: () => new Promise<void>((r) => server.close(() => r())) };
  };

  it("no secret: 401 and no counters", async () => {
    const { base, close } = await serve();
    const res = await fetch(`${base}/health/stats`);
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "Unauthorized" });
    await close();
  });

  it("right secret with a proxy header: 403 for each header", async () => {
    const { base, close } = await serve();
    for (const name of ["x-forwarded-for", "x-forwarded-host", "forwarded", "x-real-ip"]) {
      // oxlint-disable-next-line no-await-in-loop
      const res = await fetch(`${base}/health/stats`, { headers: { "live-server-secret-key": SECRET, [name]: "x" } });
      expect(res.status).toBe(403);
      // oxlint-disable-next-line no-await-in-loop
      expect(await res.json()).toEqual({ error: "Forbidden" });
    }
    await close();
  });

  it("wrong secret (same and different length): 401", async () => {
    const { base, close } = await serve();
    for (const wrong of ["x", SECRET.slice(0, -1) + "!", SECRET + "extra"]) {
      // oxlint-disable-next-line no-await-in-loop
      const res = await fetch(`${base}/health/stats`, { headers: { "live-server-secret-key": wrong } });
      expect(res.status).toBe(401);
    }
    await close();
  });

  it("right secret: 200 with uptime, start time and numbers only", async () => {
    const { base, close } = await serve();
    const res = await fetch(`${base}/health/stats`, { headers: { "live-server-secret-key": SECRET } });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.eventsEnabled).toBe(false);
    expect(body.events).toBeNull();
    expect(typeof body.uptimeSeconds).toBe("number");
    expect(Number.isNaN(Date.parse(body.startedAt))).toBe(false);
    await close();
  });

  it("right secret with a running hub: returns its counters", async () => {
    const { hub } = makeHub();
    registerStatsSource(() => hub.stats());
    const { base, close } = await serve();
    const res = await fetch(`${base}/health/stats`, { headers: { "live-server-secret-key": SECRET } });
    const body = (await res.json()) as any;
    expect(body.eventsEnabled).toBe(true);
    expect(body.events.sockets).toEqual({ open: 0, authenticated: 0, pending: 0 });
    await close();
  });

  it("public /health stays minimal", async () => {
    const { base, close } = await serve();
    const body = (await (await fetch(`${base}/health`)).json()) as Record<string, unknown>;
    expect(Object.keys(body).toSorted()).toEqual(["status", "timestamp", "version"]);
    await close();
  });
});
