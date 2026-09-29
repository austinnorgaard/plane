/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { describe, expect, it, vi } from "vitest";

vi.hoisted(() => {
  // the live env module validates these at import time
  process.env.API_BASE_URL = "http://api.invalid";
  process.env.LIVE_SERVER_SECRET_KEY = "test-value";
});

vi.mock("@/redis", () => ({ redisManager: { getClient: () => null } }));

describe("events controller isolation", () => {
  it("flag off: connections close 4404", { timeout: 30_000 }, async () => {
    delete process.env.LIVE_EVENTS_ENABLED;
    const { EventsController } = await import("@/controllers/events.controller");
    const controller = new EventsController();
    const ws = { close: vi.fn() };
    controller.handleConnection(ws as any, { headers: {} } as any);
    expect(ws.close).toHaveBeenCalledWith(4404, expect.any(String));
  });

  it("Hocuspocus controller still registers when the hub throws", { timeout: 30_000 }, async () => {
    vi.resetModules();
    process.env.LIVE_EVENTS_ENABLED = "1";
    vi.doMock("@/events/hub", () => ({
      EventsHub: vi.fn(function () {
        throw new Error("boom");
      }),
    }));
    const { CONTROLLERS } = await import("@/controllers");
    const names = CONTROLLERS.map((c) => c.name);
    expect(names).toContain("CollaborationController");
    expect(names).toContain("EventsController");
    const Events = CONTROLLERS.find((c) => c.name === "EventsController") as any;
    expect(() => new Events()).not.toThrow();
    const ws = { close: vi.fn() };
    new Events().handleConnection(ws, { headers: {} });
    expect(ws.close).toHaveBeenCalledWith(4404, expect.any(String));
    delete process.env.LIVE_EVENTS_ENABLED;
    vi.doUnmock("@/events/hub");
  });

  it("registers /events next to the Hocuspocus /collaboration route", { timeout: 30_000 }, async () => {
    vi.resetModules();
    const { CONTROLLERS } = await import("@/controllers");
    const { registerController } = await import("@plane/decorators");
    const routes: string[] = [];
    const router = { ws: (route: string) => routes.push(route), get: vi.fn(), post: vi.fn() } as any;
    CONTROLLERS.forEach((c) => registerController(router, c, [{}]));
    expect(routes).toContain("/events/");
    expect(routes).toContain("/collaboration/");
  });
});

describe("payload cap", () => {
  it("ws closes 1009 for a frame above the cap, without the hub seeing it", async () => {
    const { WebSocketServer, WebSocket } = await import("ws");
    const { limitPayload } = await import("@/events/hub");
    const wss = new WebSocketServer({ port: 0, host: "localhost" });
    await new Promise((r) => wss.once("listening", r));
    const seen: number[] = [];
    wss.on("connection", (socket) => {
      expect(limitPayload(socket, 4096)).toBe(true);
      socket.on("error", () => undefined); // the hub closes the socket on error
      socket.on("message", (d: Buffer) => seen.push(d.length));
    });
    const { port } = wss.address() as { port: number };
    const client = new WebSocket(`ws://localhost:${port}`);
    await new Promise((r) => client.once("open", r));
    client.send("x".repeat(100));
    client.send("y".repeat(5000));
    const code = await new Promise<number>((r) => client.once("close", (c) => r(c)));
    expect(code).toBe(1009);
    expect(seen).toEqual([100]);
    wss.close();
  });
});
