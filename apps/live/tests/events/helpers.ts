/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { EventEmitter } from "events";
import { vi } from "vitest";
import type { EventsAuthApi } from "@/events/auth";
import { parseEventsConfig } from "@/events/config";
import type { SocketLike, SubscriberLike } from "@/events/hub";
import { EventsHub } from "@/events/hub";

export const WEB = "https://plane.example.com";
export const P1 = "11111111-1111-4111-8111-111111111111";
export const P2 = "22222222-2222-4222-8222-222222222222";
export const P3 = "33333333-3333-4333-8333-333333333333";
export const I1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const I2 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const ACTOR = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

export class FakeSocket extends EventEmitter implements SocketLike {
  readyState = 1;
  bufferedAmount = 0;
  frames: any[] = [];
  closeCode: number | null = null;
  terminated = false;
  pings = 0;
  send(data: string) {
    this.frames.push(JSON.parse(data));
  }
  ping() {
    this.pings++;
  }
  close(code?: number) {
    this.closeCode = code ?? 1005;
    this.readyState = 3;
    this.emit("close");
  }
  terminate() {
    this.terminated = true;
    this.readyState = 3;
  }
  /** Simulate a client text frame. */
  say(message: unknown) {
    this.emit("message", Buffer.from(typeof message === "string" ? message : JSON.stringify(message)), false);
  }
  of(type: string) {
    return this.frames.filter((f) => f.type === type);
  }
}

export class FakeSubscriber extends EventEmitter implements SubscriberLike {
  patterns: string[] = [];
  quit = vi.fn(async () => undefined);
  async psubscribe(...patterns: string[]) {
    this.patterns.push(...patterns);
  }
  publish(projectId: string, message: unknown) {
    const raw = typeof message === "string" ? message : JSON.stringify(message);
    this.emit("pmessage", "plane:live-events:*", `plane:live-events:${projectId}`, raw);
  }
}

export const evt = (project_id: string, issue_ids: string[] | "*", extra: Record<string, unknown> = {}) => ({
  v: 1,
  project_id,
  issue_ids,
  kind: "issue",
  verb: "updated",
  actor_id: ACTOR,
  ts: 1,
  ...extra,
});

export type AuthState = {
  users: Record<string, { id: string } | { status: number }>; // by cookie
  roles: Record<string, Record<string, Record<string, number>>>; // slug -> cookie -> roles
  rolesError?: Record<string, number>; // slug -> status the roles call fails with
};

export const fakeAuth = (state: AuthState): EventsAuthApi & { state: AuthState } => ({
  state,
  async currentUser(cookie) {
    const user = state.users[cookie];
    if (!user || "status" in user) throw Object.assign(new Error("auth"), { statusCode: user ? user.status : 401 });
    return user;
  },
  async projectRoles(cookie, slug) {
    const failing = state.rolesError?.[slug];
    if (failing) throw Object.assign(new Error("roles"), { statusCode: failing });
    const roles = state.roles[slug]?.[cookie];
    if (!roles) throw Object.assign(new Error("roles"), { statusCode: 403 });
    return roles;
  },
});

export const ALICE = "session-id=alice";
export const BOB = "session-id=bob";

export const defaultState = (): AuthState => ({
  users: { [ALICE]: { id: "u-alice" }, [BOB]: { id: "u-bob" } },
  roles: {
    acme: { [ALICE]: { [P1]: 20, [P2]: 15 }, [BOB]: { [P3]: 20, [P1]: 5 } },
    other: { [ALICE]: { [P3]: 20 } },
  },
});

export const flushPromises = async () => {
  await vi.advanceTimersByTimeAsync(0);
};

export const makeHub = (
  env: Record<string, string> = {},
  state: AuthState = defaultState(),
  log?: { warn: (message: string) => unknown },
  random?: () => number
) => {
  const config = parseEventsConfig({ LIVE_EVENTS_ENABLED: "1", WEB_URL: WEB, ...env });
  const sub = new FakeSubscriber();
  const auth = fakeAuth(state);
  const hub = new EventsHub({ config, auth, createSubscriber: () => sub, log, random });
  return { hub, sub, auth, config };
};

export const headers = (extra: Record<string, string> = {}) => ({
  headers: { origin: WEB, host: "plane.example.com", cookie: `${ALICE}; other=1`, ...extra },
});

/** Connect a fake socket as a given cookie and wait for auth. */
export const connect = async (hub: EventsHub, cookie = ALICE, extra: Record<string, string> = {}) => {
  const ws = new FakeSocket();
  hub.handleConnection(ws, headers({ cookie, ...extra }));
  await flushPromises();
  return ws;
};

export const subscribe = async (ws: FakeSocket, slug: string, ids: string[]) => {
  ws.say({ type: "subscribe", workspace_slug: slug, project_ids: ids });
  await flushPromises();
};
