/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// plane imports
import { LIVE_BASE_PATH, LIVE_BASE_URL } from "@plane/constants";

/**
 * Frame contract, mirrored from the live hub (apps/live/src/events/hub.ts). Ids only, no content on the wire.
 *
 * client -> server
 *  - { type: "subscribe", workspace_slug, project_ids }
 *  - { type: "unsubscribe", project_ids }
 *  - { type: "pong" }                       answer to a server ping
 * server -> client
 *  - { type: "ping" }
 *  - { type: "events", project_id, items: [{ issue_id, kinds, verbs, actor_ids }], full_refresh? }
 *  - { type: "resync" }                     the hub lost its Redis subscription, every project must resync
 *  - { type: "subscribed", project_ids, denied }
 *  - { type: "unsubscribed", project_ids }
 *  - { type: "revoked", project_ids }       access to these projects was lost
 */
export type TLiveKind =
  | "issue"
  | "comment"
  | "cycle"
  | "module"
  | "link"
  | "attachment"
  | "issue_relation"
  | "issue_reaction"
  | "comment_reaction"
  | "intake";
export type TLiveVerb = "created" | "updated" | "deleted" | "removed" | "archived" | "unarchived" | "restored";

export type TLiveItem = { issue_id: string; kinds: string[]; verbs: string[]; actor_ids: string[] };

export type TLiveEventsFrame = { type: "events"; project_id: string; items: TLiveItem[]; full_refresh?: boolean };
/** emitted locally: the socket was re-established or the hub resynced, so anything may have been missed */
export type TLiveResyncFrame = { type: "resync"; project_id: string };
/** emitted locally: access to the project was lost, the project is no longer subscribed */
export type TLiveRevokedFrame = { type: "revoked"; project_id: string };

export type TLiveEvent = TLiveEventsFrame | TLiveResyncFrame | TLiveRevokedFrame;
export type TLiveListener = (event: TLiveEvent) => void;

type TServerFrame =
  | TLiveEventsFrame
  | { type: "ping" }
  | { type: "resync" }
  | { type: "subscribed"; project_ids: string[]; denied: string[] }
  | { type: "unsubscribed" }
  | { type: "revoked"; project_ids: string[] };

export const LIVE_CLOSE_BAD_MESSAGE = 4400;
export const LIVE_CLOSE_UNAUTHENTICATED = 4401;
export const LIVE_CLOSE_FORBIDDEN = 4403;
export const LIVE_CLOSE_NOT_FOUND = 4404;
export const LIVE_CLOSE_TOO_LARGE = 4413;
export const LIVE_CLOSE_RATE_LIMITED = 4429;

export const BACKOFF_MIN_MS = 1000;
export const BACKOFF_MAX_MS = 30_000;
export const WATCHDOG_MS = 60_000;
export const HIDDEN_CLOSE_MS = 5 * 60_000;
export const HIDDEN_BUFFER_CAP = 200;

/**
 * Exponential backoff between BACKOFF_MIN_MS and BACKOFF_MAX_MS with jitter (50%-100% of the step).
 * `random` is injectable so the function stays pure.
 */
export const getBackoffDelay = (attempt: number, random: number = Math.random()): number => {
  const step = Math.min(BACKOFF_MAX_MS, BACKOFF_MIN_MS * 2 ** Math.max(0, attempt));
  return Math.max(BACKOFF_MIN_MS, Math.round(step * (0.5 + 0.5 * random)));
};

/** Reconnect policy for a close code. */
export type TCloseDecision = "retry" | "retry-max" | "pause" | "stop";
export const decideOnClose = (code: number): TCloseDecision => {
  switch (code) {
    case LIVE_CLOSE_UNAUTHENTICATED:
      return "pause";
    // 4403 origin not allowed, 4404 live events disabled: stopped until the next full page load
    case LIVE_CLOSE_FORBIDDEN:
    case LIVE_CLOSE_NOT_FOUND:
    // 4400 and 4413 mean the server rejected what this client sent; retrying would only repeat it
    case LIVE_CLOSE_BAD_MESSAGE:
    case LIVE_CLOSE_TOO_LARGE:
      return "stop";
    case LIVE_CLOSE_RATE_LIMITED:
      return "retry-max";
    default:
      return "retry";
  }
};

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;

const stringArray = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];

/** Validates a raw text frame. Returns undefined for anything malformed or unknown. */
export const parseFrame = (raw: unknown): TServerFrame | undefined => {
  if (typeof raw !== "string") return undefined;
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!isRecord(data)) return undefined;
  switch (data.type) {
    case "ping":
    case "resync":
    case "unsubscribed":
      return { type: data.type };
    case "subscribed":
      return { type: "subscribed", project_ids: stringArray(data.project_ids), denied: stringArray(data.denied) };
    case "revoked":
      return { type: "revoked", project_ids: stringArray(data.project_ids) };
    case "events": {
      if (typeof data.project_id !== "string" || !Array.isArray(data.items)) return undefined;
      const items: TLiveItem[] = [];
      for (const item of data.items) {
        if (!isRecord(item) || typeof item.issue_id !== "string") continue;
        items.push({
          issue_id: item.issue_id,
          kinds: stringArray(item.kinds),
          verbs: stringArray(item.verbs),
          actor_ids: stringArray(item.actor_ids),
        });
      }
      return { type: "events", project_id: data.project_id, items, full_refresh: data.full_refresh === true };
    }
    default:
      return undefined;
  }
};

/** Number of ids a frame adds to the hidden-tab buffer (a full refresh counts as one). */
const frameWeight = (event: TLiveEvent) => (event.type === "events" ? Math.max(1, event.items.length) : 1);

export const buildLiveEventsUrl = (): string | undefined => {
  if (typeof window === "undefined") return undefined;
  try {
    // built like the page collaboration url: base url (or the page origin), ws/wss by page protocol
    const LIVE_SERVER_BASE_URL = LIVE_BASE_URL?.trim() || window.location.origin;
    const url = new URL(LIVE_SERVER_BASE_URL);
    url.protocol = window.location.protocol === "https:" ? "wss" : "ws";
    url.pathname = `${LIVE_BASE_PATH}/events`;
    return url.toString();
  } catch {
    return undefined;
  }
};

/**
 * One socket per tab, shared by every subscriber. Subscriptions are ref-counted per project.
 * Authentication is the session cookie sent with the upgrade request; nothing else is sent.
 */
export class LiveEventsClient {
  private listeners = new Map<string, Set<TLiveListener>>();
  private workspaceSlugs = new Map<string, string>();
  /** projects the hub refused; not re-requested until every subscriber of the project is gone */
  private denied = new Set<string>();
  private socket: WebSocket | undefined;
  private socketAbort: AbortController | undefined;
  private attempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  private watchdogTimer: ReturnType<typeof setTimeout> | undefined;
  private hiddenTimer: ReturnType<typeof setTimeout> | undefined;
  private forceMaxBackoff = false;
  private pausedUntilActivity = false;
  private stopped = false;
  private closedWhileHidden = false;
  private needsResync = false;
  private hiddenBuffer: TLiveEvent[] = [];
  private hiddenBufferWeight = 0;
  private hiddenOverflow = false;
  private globalListenersAttached = false;

  /** Subscribes to a project. Returns the unsubscribe function. */
  subscribe(workspaceSlug: string, projectId: string, listener: TLiveListener): () => void {
    let set = this.listeners.get(projectId);
    const isFirstForProject = !set;
    if (!set) {
      set = new Set();
      this.listeners.set(projectId, set);
    }
    set.add(listener);
    this.attachGlobalListeners();
    // a navigation counts as user activity: it lifts a 4401 pause
    this.pausedUntilActivity = false;

    this.workspaceSlugs.set(projectId, workspaceSlug);
    if (isFirstForProject) this.sendSubscribe([projectId]);
    this.ensureConnected();

    let active = true;
    return () => {
      if (!active) return;
      active = false;
      const current = this.listeners.get(projectId);
      if (!current) return;
      current.delete(listener);
      if (current.size > 0) return;
      this.listeners.delete(projectId);
      this.workspaceSlugs.delete(projectId);
      this.denied.delete(projectId);
      this.send({ type: "unsubscribe", project_ids: [projectId] });
      if (this.listeners.size === 0) this.shutdown();
    };
  }

  // ---- connection ----

  private isOnline = () => typeof navigator === "undefined" || navigator.onLine !== false;
  private isHidden = () => typeof document !== "undefined" && document.visibilityState === "hidden";

  private ensureConnected() {
    if (this.listeners.size === 0 || this.stopped || this.pausedUntilActivity) return;
    if (this.socket || this.reconnectTimer) return;
    if (!this.isOnline()) return;
    // a socket closed for being hidden stays closed until the tab is visible again
    if (this.closedWhileHidden && this.isHidden()) return;
    this.connect();
  }

  private connect() {
    const url = buildLiveEventsUrl();
    if (!url || typeof WebSocket === "undefined") return;
    let socket: WebSocket;
    try {
      socket = new WebSocket(url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.socket = socket;
    this.closedWhileHidden = false;

    const abort = new AbortController();
    this.socketAbort = abort;
    const { signal } = abort;

    socket.addEventListener(
      "open",
      () => {
        this.attempt = 0;
        this.forceMaxBackoff = false;
        this.resetWatchdog();
        // roles may have changed while the socket was down: ask again
        this.denied.clear();
        this.sendSubscribe([...this.listeners.keys()]);
        // anything may have been missed while the socket was down
        if (this.needsResync) {
          this.needsResync = false;
          this.emitResync();
        }
      },
      { signal }
    );
    socket.addEventListener(
      "message",
      (message) => {
        this.resetWatchdog();
        const frame = parseFrame(message.data);
        if (frame) this.handleFrame(frame);
      },
      { signal }
    );
    socket.addEventListener(
      "close",
      (closeEvent) => {
        // a close event for a socket that was already replaced is ignored by the abort signal
        this.socket = undefined;
        this.socketAbort = undefined;
        this.clearWatchdog();
        this.needsResync = true;
        this.handleClose(closeEvent.code);
      },
      { signal }
    );
  }

  private handleClose(code: number) {
    if (this.listeners.size === 0) return;
    if (this.closedWhileHidden) return;
    const decision = decideOnClose(code);
    if (decision === "stop") {
      this.stopped = true;
      if (code === LIVE_CLOSE_BAD_MESSAGE || code === LIVE_CLOSE_TOO_LARGE) {
        console.error(`live events stopped: the server rejected a message (close code ${code})`);
      }
      return;
    }
    if (decision === "pause") {
      this.pausedUntilActivity = true;
      return;
    }
    if (decision === "retry-max") this.forceMaxBackoff = true;
    this.scheduleReconnect();
  }

  private scheduleReconnect() {
    if (this.reconnectTimer || this.stopped || this.pausedUntilActivity || this.listeners.size === 0) return;
    if (!this.isOnline()) return; // the online event reconnects
    const delay = this.forceMaxBackoff ? getBackoffDelay(Infinity) : getBackoffDelay(this.attempt);
    this.attempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.ensureConnected();
    }, delay);
  }

  private closeSocket(code = 1000) {
    const socket = this.socket;
    this.socket = undefined;
    this.clearWatchdog();
    if (!socket) return;
    this.socketAbort?.abort();
    this.socketAbort = undefined;
    try {
      socket.close(code);
    } catch {
      // already closed
    }
  }

  private shutdown() {
    this.closeSocket();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.clearHiddenTimer();
    this.detachGlobalListeners();
    this.attempt = 0;
    this.forceMaxBackoff = false;
    this.needsResync = false;
    this.denied.clear();
    this.hiddenBuffer = [];
    this.hiddenBufferWeight = 0;
    this.hiddenOverflow = false;
  }

  /** one subscribe message per workspace, denied projects are skipped */
  private sendSubscribe(projectIds: string[]) {
    const bySlug = new Map<string, string[]>();
    for (const projectId of projectIds) {
      const slug = this.workspaceSlugs.get(projectId);
      if (!slug || this.denied.has(projectId)) continue;
      bySlug.set(slug, [...(bySlug.get(slug) ?? []), projectId]);
    }
    for (const [workspace_slug, project_ids] of bySlug) this.send({ type: "subscribe", workspace_slug, project_ids });
  }

  private handleFrame(frame: TServerFrame) {
    switch (frame.type) {
      case "ping":
        this.send({ type: "pong" });
        return;
      case "events":
        this.dispatch(frame);
        return;
      case "resync":
        // sent by the hub without a project: every project resyncs
        this.emitResync();
        return;
      case "subscribed":
        frame.denied.forEach((projectId) => this.denied.add(projectId));
        return;
      case "revoked":
        for (const projectId of frame.project_ids) {
          this.denied.add(projectId);
          this.emit({ type: "revoked", project_id: projectId });
        }
        return;
      case "unsubscribed":
        return;
    }
  }

  private send(
    payload:
      | { type: "subscribe"; workspace_slug: string; project_ids: string[] }
      | { type: "unsubscribe"; project_ids: string[] }
      | { type: "pong" }
  ) {
    if (this.socket?.readyState !== 1) return; // subscriptions are re-sent on open
    try {
      this.socket.send(JSON.stringify(payload));
    } catch {
      // the close handler recovers
    }
  }

  // ---- watchdog ----

  private resetWatchdog() {
    this.clearWatchdog();
    this.watchdogTimer = setTimeout(() => {
      // no frame (not even a ping) for WATCHDOG_MS: the connection is dead, force a reconnect
      this.closeSocket(4000);
      this.needsResync = true;
      this.scheduleReconnect();
    }, WATCHDOG_MS);
  }

  private clearWatchdog() {
    if (this.watchdogTimer) clearTimeout(this.watchdogTimer);
    this.watchdogTimer = undefined;
  }

  // ---- dispatch and hidden-tab buffer ----

  private dispatch(event: TLiveEvent) {
    if (!this.listeners.has(event.project_id)) return;
    if (this.isHidden()) {
      this.bufferHidden(event);
      return;
    }
    this.emit(event);
  }

  private emit(event: TLiveEvent) {
    for (const listener of this.listeners.get(event.project_id) ?? []) {
      try {
        listener(event);
      } catch (error) {
        console.error("live events listener failed", error);
      }
    }
  }

  private emitResync() {
    for (const projectId of this.listeners.keys()) this.emit({ type: "resync", project_id: projectId });
  }

  private bufferHidden(event: TLiveEvent) {
    if (this.hiddenOverflow) return;
    this.hiddenBufferWeight += frameWeight(event);
    if (this.hiddenBufferWeight > HIDDEN_BUFFER_CAP) {
      // too much to replay one by one: a single resync per project is cheaper
      this.hiddenOverflow = true;
      this.hiddenBuffer = [];
      return;
    }
    this.hiddenBuffer.push(event);
  }

  private flushHiddenBuffer() {
    const buffered = this.hiddenBuffer;
    const overflow = this.hiddenOverflow;
    this.hiddenBuffer = [];
    this.hiddenBufferWeight = 0;
    this.hiddenOverflow = false;
    if (overflow) this.emitResync();
    else buffered.forEach((event) => this.emit(event));
  }

  // ---- page lifecycle ----

  private clearHiddenTimer() {
    if (this.hiddenTimer) clearTimeout(this.hiddenTimer);
    this.hiddenTimer = undefined;
  }

  private onVisibilityChange = () => {
    if (this.isHidden()) {
      this.clearHiddenTimer();
      this.hiddenTimer = setTimeout(() => {
        // hidden for too long: give the server its socket back and resync when the tab returns
        this.hiddenTimer = undefined;
        this.closedWhileHidden = true;
        this.needsResync = true;
        this.hiddenBuffer = [];
        this.hiddenBufferWeight = 0;
        this.hiddenOverflow = false;
        this.closeSocket();
        if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
        this.reconnectTimer = undefined;
      }, HIDDEN_CLOSE_MS);
      return;
    }
    this.clearHiddenTimer();
    this.onActivity();
    if (this.socket) this.flushHiddenBuffer();
  };

  /** focus and visibility lift a 4401 pause and wake a closed socket */
  private onActivity = () => {
    this.pausedUntilActivity = false;
    this.ensureConnected();
  };

  private onOnline = () => {
    this.attempt = 0;
    this.needsResync = true;
    this.ensureConnected();
  };

  private onOffline = () => {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.closeSocket();
    this.needsResync = true;
  };

  private attachGlobalListeners() {
    if (this.globalListenersAttached || typeof window === "undefined") return;
    this.globalListenersAttached = true;
    document.addEventListener("visibilitychange", this.onVisibilityChange);
    window.addEventListener("focus", this.onActivity);
    window.addEventListener("online", this.onOnline);
    window.addEventListener("offline", this.onOffline);
  }

  private detachGlobalListeners() {
    if (!this.globalListenersAttached || typeof window === "undefined") return;
    this.globalListenersAttached = false;
    document.removeEventListener("visibilitychange", this.onVisibilityChange);
    window.removeEventListener("focus", this.onActivity);
    window.removeEventListener("online", this.onOnline);
    window.removeEventListener("offline", this.onOffline);
  }
}

let singleton: LiveEventsClient | undefined;
export const getLiveEventsClient = (): LiveEventsClient => (singleton ??= new LiveEventsClient());
