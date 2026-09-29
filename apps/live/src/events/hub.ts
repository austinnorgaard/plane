/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import type { IncomingHttpHeaders } from "http";
import { z } from "zod";
import { logger } from "@plane/logger";
import type { EventsAuthApi } from "./auth";
import { CLOSE_AUTH, extractSessionCookie, isSessionGone, isValidWorkspaceSlug, partitionProjects } from "./auth";
import type { EventsConfig } from "./config";
import { EVENTS_CHANNEL_PATTERN, EVENTS_CHANNEL_PREFIX } from "./config";
import { buildAllowlist, CLOSE_ORIGIN, isOriginAllowed } from "./origin";

// Close codes used by the events socket.
export const CLOSE_BAD_MESSAGE = 4400;
export const CLOSE_DISABLED = 4404;
export const CLOSE_DEADLINE = 4408;
export const CLOSE_TOO_LARGE = 4413;
export const CLOSE_LIMIT = 4429;
export const CLOSE_UNAVAILABLE = 1013;

const OPEN = 1;

/** The subset of a ws WebSocket the hub uses. */
export interface SocketLike {
  readyState: number;
  bufferedAmount: number;
  on(event: string, listener: (...args: any[]) => void): unknown;
  send(data: string): void;
  ping(): void;
  close(code?: number, reason?: string): void;
  terminate(): void;
}

/** The subset of an ioredis subscriber connection the hub uses. */
export interface SubscriberLike {
  on(event: string, listener: (...args: any[]) => void): unknown;
  psubscribe(...patterns: string[]): Promise<unknown>;
  quit(): Promise<unknown>;
}

export type HubDeps = {
  config: EventsConfig;
  auth: EventsAuthApi;
  createSubscriber: () => SubscriberLike | null;
};

export const EVENT_KINDS = [
  "issue",
  "comment",
  "cycle",
  "module",
  "link",
  "attachment",
  "issue_relation",
  "issue_reaction",
  "comment_reaction",
  "intake",
] as const;
export const EVENT_VERBS = ["created", "updated", "deleted", "removed", "archived", "unarchived", "restored"] as const;

const MAX_IDS = 500;
const MAX_SETTLE_TIMERS_PER_PROJECT = 20;

// The API publisher names the id list `ids`; the design names it `issue_ids`. Accept both.
const withIssueIds = (raw: unknown) => {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    const obj = raw as Record<string, unknown>;
    if (obj.issue_ids === undefined && obj.ids !== undefined) return { ...obj, issue_ids: obj.ids };
  }
  return raw;
};

const redisEventShape = z.object({
  v: z.literal(1),
  project_id: z.string().uuid(),
  issue_ids: z.union([z.array(z.string().uuid()).max(MAX_IDS), z.literal("*")]),
  kind: z.enum(EVENT_KINDS),
  verb: z.enum(EVENT_VERBS),
  actor_id: z.string().uuid().nullish(),
  ts: z.union([z.number(), z.string()]).optional(),
  settle: z.boolean().optional(),
});
export const redisMessageSchema = z.preprocess(withIssueIds, redisEventShape);
export type RedisEvent = z.infer<typeof redisEventShape>;

const clientMessageSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("subscribe"),
    workspace_slug: z.string(),
    project_ids: z.array(z.string().uuid()).max(1000),
  }),
  z.object({ type: z.literal("unsubscribe"), project_ids: z.array(z.string().uuid()).max(1000) }),
  z.object({ type: z.literal("pong") }),
]);

type Item = { issue_id: string; kinds: Set<string>; verbs: Set<string>; actor_ids: Set<string> };
type Pending = { items: Map<string, Item>; full: boolean; timer: ReturnType<typeof setTimeout> | null };

type Client = {
  ws: SocketLike;
  cookie: string;
  userId: string | null;
  authed: Promise<boolean>;
  chain: Promise<void>;
  projects: Map<string, string>; // project id -> workspace slug
  missedPongs: number;
  inboundStart: number;
  inboundCount: number;
  deadline: ReturnType<typeof setTimeout> | null;
  closed: boolean;
};

/**
 * Make ws itself refuse frames above `bytes` (it closes 1009 before buffering the payload).
 * express-ws creates its servers with ws defaults (100 MiB) and is shared with the Hocuspocus
 * endpoint, so the limit is applied to this endpoint's sockets only, on the socket's receiver.
 * If ws internals ever change, the per-message size check in onClientMessage still applies.
 */
export const limitPayload = (ws: unknown, bytes: number): boolean => {
  const receiver = (ws as { _receiver?: { _maxPayload?: number } } | null)?._receiver;
  if (!receiver || typeof receiver._maxPayload !== "number") return false;
  receiver._maxPayload = bytes;
  return true;
};

export class EventsHub {
  private readonly config: EventsConfig;
  private readonly auth: EventsAuthApi;
  private readonly createSubscriber: () => SubscriberLike | null;
  private readonly allowlist: Set<string>;
  private readonly clients = new Set<Client>();
  private readonly byProject = new Map<string, Set<Client>>();
  private readonly pending = new Map<string, Pending>();
  private readonly rate = new Map<string, { start: number; count: number }>();
  private readonly settleTimers = new Set<ReturnType<typeof setTimeout>>();
  private readonly settleState = new Map<string, { count: number; wildcard: ReturnType<typeof setTimeout> | null }>();
  private subscriber: SubscriberLike | null = null;
  private seenReady = false;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private revalidateTimer: ReturnType<typeof setInterval> | null = null;
  private revalidating = false;
  private stopped = false;
  invalidDropped = 0;

  constructor(deps: HubDeps) {
    this.config = deps.config;
    this.auth = deps.auth;
    this.createSubscriber = deps.createSubscriber;
    this.allowlist = buildAllowlist([...deps.config.allowedOrigins, ...deps.config.corsOrigins, deps.config.webUrl]);
  }

  get socketCount() {
    return this.clients.size;
  }

  /** Start the Redis subscriber and timers. A no-op when the flag is off. */
  async start(): Promise<void> {
    if (!this.config.enabled) return;
    const sub = this.createSubscriber();
    if (!sub) {
      logger.warn("LIVE_EVENTS: no Redis connection available, events hub is idle");
      return;
    }
    this.subscriber = sub;
    sub.on("pmessage", (_pattern: string, channel: string, raw: string) => this.onRedisMessage(channel, raw));
    sub.on("ready", () => {
      if (this.seenReady) this.broadcast({ type: "resync" });
      this.seenReady = true;
    });
    sub.on("error", (error: unknown) => {
      logger.error("LIVE_EVENTS: subscriber error", error instanceof Error ? error.message : "unknown");
    });
    this.pingTimer = setInterval(() => this.heartbeat(), this.config.pingIntervalMs);
    this.revalidateTimer = setInterval(() => void this.revalidateAll(), this.config.revalidateMs);
    this.pingTimer.unref?.();
    this.revalidateTimer.unref?.();
    await sub.psubscribe(EVENTS_CHANNEL_PATTERN);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.pingTimer) clearInterval(this.pingTimer);
    if (this.revalidateTimer) clearInterval(this.revalidateTimer);
    this.settleTimers.forEach((t) => clearTimeout(t));
    this.settleTimers.clear();
    this.settleState.clear();
    this.pending.forEach((p) => p.timer && clearTimeout(p.timer));
    this.pending.clear();
    for (const client of this.clients) this.close(client, 1001, "shutdown");
    try {
      await this.subscriber?.quit();
    } catch {
      // ignore: connection already gone
    }
  }

  // ---------------------------------------------------------------- sockets

  handleConnection(ws: SocketLike, req: { headers: IncomingHttpHeaders }): void {
    const reject = (code: number, reason: string) => {
      try {
        ws.close(code, reason);
      } catch {
        // ignore
      }
    };
    if (!this.config.enabled) return reject(CLOSE_DISABLED, "live events disabled");
    limitPayload(ws, this.config.maxMessageBytes);
    if (this.stopped || !this.subscriber) return reject(CLOSE_UNAVAILABLE, "unavailable");
    const headers = req.headers;
    if (
      !isOriginAllowed(
        { origin: headers.origin, host: headers.host, forwardedHost: headers["x-forwarded-host"] },
        this.allowlist
      )
    ) {
      return reject(CLOSE_ORIGIN, "origin not allowed");
    }
    const cookie = extractSessionCookie(headers.cookie);
    if (!cookie) return reject(CLOSE_AUTH, "unauthenticated");
    if (this.clients.size >= this.config.maxSockets) return reject(CLOSE_LIMIT, "too many connections");

    const client: Client = {
      ws,
      cookie,
      userId: null,
      authed: Promise.resolve(false),
      chain: Promise.resolve(),
      projects: new Map(),
      missedPongs: 0,
      inboundStart: Date.now(),
      inboundCount: 0,
      deadline: null,
      closed: false,
    };
    this.clients.add(client);
    client.deadline = setTimeout(
      () => this.close(client, CLOSE_DEADLINE, "no message received"),
      this.config.firstMessageMs
    );

    client.authed = this.auth
      .currentUser(cookie)
      .then((user) => {
        if (client.closed) return false;
        client.userId = user.id;
        const sameUser = [...this.clients].filter((c) => c !== client && c.userId === user.id).length;
        if (sameUser >= this.config.maxSocketsPerUser) {
          this.close(client, CLOSE_LIMIT, "too many connections for user");
          return false;
        }
        return true;
      })
      .catch(() => {
        this.close(client, CLOSE_AUTH, "unauthenticated");
        return false;
      });

    ws.on("message", (data: unknown, isBinary?: boolean) => this.onClientMessage(client, data, isBinary));
    ws.on("pong", () => {
      client.missedPongs = 0;
    });
    ws.on("close", () => this.release(client));
    ws.on("error", () => this.close(client, 1011, "socket error"));
  }

  private onClientMessage(client: Client, data: unknown, isBinary?: boolean): void {
    if (client.closed) return;
    if (client.deadline) {
      clearTimeout(client.deadline);
      client.deadline = null;
    }
    const now = Date.now();
    if (now - client.inboundStart >= 1000) {
      client.inboundStart = now;
      client.inboundCount = 0;
    }
    if (++client.inboundCount > this.config.maxInboundPerSec) {
      return this.close(client, CLOSE_LIMIT, "message rate exceeded");
    }
    const size = Array.isArray(data)
      ? data.reduce((n: number, b: Buffer) => n + b.length, 0)
      : ((data as { byteLength?: number })?.byteLength ?? String(data).length);
    if (size > this.config.maxMessageBytes) return this.close(client, CLOSE_TOO_LARGE, "message too large");
    if (isBinary) return this.close(client, CLOSE_BAD_MESSAGE, "text frames only");

    const text = Array.isArray(data) ? Buffer.concat(data as Buffer[]).toString("utf8") : String(data);
    let message: z.infer<typeof clientMessageSchema>;
    try {
      message = clientMessageSchema.parse(JSON.parse(text));
    } catch {
      return this.close(client, CLOSE_BAD_MESSAGE, "invalid message");
    }
    client.chain = client.chain
      .then(() => this.processClientMessage(client, message))
      .catch(() => this.close(client, 1011, "internal error"));
  }

  private async processClientMessage(client: Client, message: z.infer<typeof clientMessageSchema>) {
    if (!(await client.authed) || client.closed) return;
    if (message.type === "pong") {
      client.missedPongs = 0;
      return;
    }
    if (message.type === "unsubscribe") {
      for (const id of message.project_ids) this.removeProject(client, id);
      this.send(client, { type: "unsubscribed", project_ids: message.project_ids });
      return;
    }
    if (!isValidWorkspaceSlug(message.workspace_slug)) {
      return this.close(client, CLOSE_BAD_MESSAGE, "invalid workspace");
    }
    const requested = [...new Set(message.project_ids)];
    const total = new Set([...client.projects.keys(), ...requested]).size;
    if (total > this.config.maxProjectsPerSocket) return this.close(client, CLOSE_LIMIT, "too many projects");

    let roles: Record<string, number>;
    try {
      roles = await this.auth.projectRoles(client.cookie, message.workspace_slug);
    } catch (error) {
      if (isSessionGone(error)) return this.close(client, CLOSE_AUTH, "session ended");
      // membership could not be established: grant nothing
      this.send(client, { type: "subscribed", project_ids: [], denied: requested });
      return;
    }
    if (client.closed) return;
    const { granted, denied } = partitionProjects(requested, roles);
    for (const id of granted) this.addProject(client, id, message.workspace_slug);
    this.send(client, { type: "subscribed", project_ids: granted, denied });
  }

  private addProject(client: Client, projectId: string, slug: string) {
    client.projects.set(projectId, slug);
    let set = this.byProject.get(projectId);
    if (!set) this.byProject.set(projectId, (set = new Set()));
    set.add(client);
  }

  private removeProject(client: Client, projectId: string) {
    client.projects.delete(projectId);
    const set = this.byProject.get(projectId);
    if (!set) return;
    set.delete(client);
    if (set.size === 0) {
      this.byProject.delete(projectId);
      const p = this.pending.get(projectId);
      if (p?.timer) clearTimeout(p.timer);
      this.pending.delete(projectId);
    }
  }

  private release(client: Client) {
    if (client.closed) return;
    client.closed = true;
    if (client.deadline) clearTimeout(client.deadline);
    for (const id of client.projects.keys()) this.removeProject(client, id);
    this.clients.delete(client);
  }

  private close(client: Client, code: number, reason: string) {
    this.release(client);
    try {
      client.ws.close(code, reason);
    } catch {
      // ignore
    }
  }

  private send(client: Client, frame: unknown): boolean {
    if (client.closed || client.ws.readyState !== OPEN) return false;
    if (client.ws.bufferedAmount > this.config.maxBufferedBytes) {
      this.close(client, CLOSE_LIMIT, "client too slow");
      return false;
    }
    try {
      client.ws.send(JSON.stringify(frame));
      return true;
    } catch {
      this.close(client, 1011, "send failed");
      return false;
    }
  }

  private broadcast(frame: unknown) {
    for (const client of this.clients) this.send(client, frame);
  }

  // -------------------------------------------------------------- heartbeat

  private heartbeat() {
    for (const client of this.clients) {
      if (client.missedPongs >= this.config.maxMissedPongs) {
        this.release(client);
        try {
          client.ws.terminate();
        } catch {
          // ignore
        }
        continue;
      }
      client.missedPongs++;
      try {
        client.ws.ping();
      } catch {
        // ignore: the next tick terminates it
      }
      this.send(client, { type: "ping" });
    }
  }

  // ------------------------------------------------------------ revalidation

  async revalidateAll(): Promise<void> {
    if (this.revalidating) return;
    this.revalidating = true;
    try {
      const all = [...this.clients];
      for (let i = 0; i < all.length; i += 10) {
        // oxlint-disable-next-line no-await-in-loop
        await Promise.all(all.slice(i, i + 10).map((c) => this.revalidate(c).catch(() => undefined)));
      }
    } finally {
      this.revalidating = false;
    }
  }

  private async revalidate(client: Client) {
    if (client.closed || !client.userId) return;
    try {
      const user = await this.auth.currentUser(client.cookie);
      if (user.id !== client.userId) return this.close(client, CLOSE_AUTH, "session changed");
    } catch (error) {
      // a transient failure keeps the socket; the next cycle retries
      if (isSessionGone(error)) this.close(client, CLOSE_AUTH, "session ended");
      return;
    }
    for (const slug of new Set(client.projects.values())) {
      if (client.closed) return;
      let roles: Record<string, number>;
      try {
        // oxlint-disable-next-line no-await-in-loop
        roles = await this.auth.projectRoles(client.cookie, slug);
      } catch (error) {
        if (isSessionGone(error)) this.close(client, CLOSE_AUTH, "session ended");
        continue;
      }
      const mine = [...client.projects].filter(([, s]) => s === slug).map(([id]) => id);
      const { denied } = partitionProjects(mine, roles);
      if (denied.length > 0) {
        for (const id of denied) this.removeProject(client, id);
        this.send(client, { type: "revoked", project_ids: denied });
      }
    }
  }

  // ------------------------------------------------------------------ redis

  private onRedisMessage(channel: string, raw: string) {
    try {
      const parsed = redisMessageSchema.safeParse(JSON.parse(raw));
      const channelProject = channel.startsWith(EVENTS_CHANNEL_PREFIX)
        ? channel.slice(EVENTS_CHANNEL_PREFIX.length)
        : "";
      if (!parsed.success || parsed.data.project_id !== channelProject) {
        this.invalidDropped++;
        return;
      }
      this.ingest(parsed.data, false);
    } catch {
      this.invalidDropped++;
    }
  }

  private ingest(event: RedisEvent, fromSettle: boolean) {
    const projectId = event.project_id;
    if (!this.byProject.has(projectId)) return;

    const now = Date.now();
    let rate = this.rate.get(projectId);
    if (!rate || now - rate.start >= 1000) this.rate.set(projectId, (rate = { start: now, count: 0 }));
    const overflow = ++rate.count > this.config.projectRatePerSec;

    let pending = this.pending.get(projectId);
    if (!pending) this.pending.set(projectId, (pending = { items: new Map(), full: false, timer: null }));

    // Over the limit, or a project-wide event: nothing is dropped, the whole window
    // collapses into one full refresh.
    if (overflow || event.issue_ids === "*") this.markFull(pending);
    else if (!pending.full) {
      for (const id of event.issue_ids) {
        let item = pending.items.get(id);
        if (!item)
          pending.items.set(id, (item = { issue_id: id, kinds: new Set(), verbs: new Set(), actor_ids: new Set() }));
        item.kinds.add(event.kind);
        item.verbs.add(event.verb);
        if (event.actor_id) item.actor_ids.add(event.actor_id);
      }
      if (pending.items.size > this.config.maxItemsPerFrame) this.markFull(pending);
    }
    if (!pending.timer) pending.timer = setTimeout(() => this.flush(projectId), this.config.coalesceMs);

    if (event.settle && !fromSettle) this.scheduleSettle(event);
  }

  // At most MAX_SETTLE_TIMERS_PER_PROJECT individual re-emits are pending per project. Beyond
  // that a single project-wide re-emit is (re)started, so timers stay bounded under a burst.
  private scheduleSettle(event: RedisEvent) {
    const projectId = event.project_id;
    let state = this.settleState.get(projectId);
    if (!state) this.settleState.set(projectId, (state = { count: 0, wildcard: null }));
    const st = state;
    const arm = (fire: () => void) => {
      const timer = setTimeout(() => {
        this.settleTimers.delete(timer);
        fire();
        if (st.count === 0 && !st.wildcard) this.settleState.delete(projectId);
      }, this.config.settleMs);
      this.settleTimers.add(timer);
      return timer;
    };
    if (st.count < MAX_SETTLE_TIMERS_PER_PROJECT) {
      st.count++;
      arm(() => {
        st.count--;
        this.ingest({ ...event, settle: false }, true);
      });
      return;
    }
    if (st.wildcard) {
      clearTimeout(st.wildcard);
      this.settleTimers.delete(st.wildcard);
    }
    st.wildcard = arm(() => {
      st.wildcard = null;
      this.ingest({ ...event, issue_ids: "*", settle: false }, true);
    });
  }

  private markFull(pending: Pending) {
    pending.full = true;
    pending.items.clear();
  }

  private flush(projectId: string) {
    const pending = this.pending.get(projectId);
    this.pending.delete(projectId);
    const clients = this.byProject.get(projectId);
    if (!pending || !clients || clients.size === 0) return;
    const frame: Record<string, unknown> = {
      type: "events",
      project_id: projectId,
      items: pending.full
        ? []
        : [...pending.items.values()].map((i) => ({
            issue_id: i.issue_id,
            kinds: [...i.kinds],
            verbs: [...i.verbs],
            actor_ids: [...i.actor_ids],
          })),
    };
    if (pending.full) frame.full_refresh = true;
    for (const client of clients) this.send(client, frame);
  }
}
