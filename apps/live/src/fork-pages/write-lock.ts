/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

// fork (PLN-98): document write lock for the pages API.
//
// An api PATCH asks for the lock right before its database commit. The lock is granted only while the
// page is not loaded in this process (checked and set in one synchronous step, so no load can slip in
// between), and while it is held every new load of that page waits in onLoadDocument until the lock is
// released (after the api commit) or expires. The loading editor therefore always reads the committed
// state, and the api write can never be overwritten by an editor that read the old state.
//
// Single live replica only (like the presence check): the lock is per process.

import { randomUUID } from "crypto";
import type { Extension, onLoadDocumentPayload } from "@hocuspocus/server";

const DEFAULT_TTL_MS = 15_000;
const MAX_TTL_MS = 60_000;

type Lock = { token: string; expires: number; timer: ReturnType<typeof setTimeout>; waiters: Array<() => void> };

const locks = new Map<string, Lock>();

/** Lock lifetime (PAGES_WRITE_LOCK_TTL_MS, default 15 s, at most 60 s), read per call. */
export const getWriteLockTtlMs = (): number => {
  const parsed = Number.parseInt(process.env.PAGES_WRITE_LOCK_TTL_MS ?? "", 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) return DEFAULT_TTL_MS;
  return Math.min(parsed, MAX_TTL_MS);
};

const drop = (pageId: string, lock: Lock) => {
  if (locks.get(pageId) !== lock) return;
  clearTimeout(lock.timer);
  locks.delete(pageId);
  for (const resolve of lock.waiters) resolve();
};

export type AcquireResult = { acquired: true; token: string; ttlMs: number } | { acquired: false; reason: "busy" };

/**
 * Takes the lock unless another writer holds it. The caller checks presence in the same synchronous
 * step (see the controller); nothing here awaits, so the check and the set cannot interleave with a load.
 */
export const acquireWriteLock = (pageId: string): AcquireResult => {
  const existing = locks.get(pageId);
  if (existing && existing.expires > Date.now()) return { acquired: false, reason: "busy" };
  if (existing) drop(pageId, existing);
  const ttlMs = getWriteLockTtlMs();
  const lock: Lock = {
    token: randomUUID(),
    expires: Date.now() + ttlMs,
    timer: setTimeout(() => drop(pageId, lock), ttlMs),
    waiters: [],
  };
  lock.timer.unref?.();
  locks.set(pageId, lock);
  return { acquired: true, token: lock.token, ttlMs };
};

/** Releases the lock when the token matches. Returns false when it was not held (expired or never taken). */
export const releaseWriteLock = (pageId: string, token: string): boolean => {
  const lock = locks.get(pageId);
  if (!lock || lock.token !== token) return false;
  drop(pageId, lock);
  return true;
};

/** Resolves once the page is not write-locked (immediately when it is not). */
export const waitForWriteUnlock = (pageId: string): Promise<void> => {
  const lock = locks.get(pageId);
  if (!lock) return Promise.resolve();
  return new Promise((resolve) => lock.waiters.push(resolve));
};

/**
 * Holds back the load of a write-locked page until the api write committed. It runs before the
 * Database extension's fetch: hooks run in priority order, highest first, one after the other.
 */
export class PageWriteLockExtension implements Extension {
  priority = 1000;
  extensionName = "PageWriteLock";

  async onLoadDocument({ documentName }: onLoadDocumentPayload): Promise<void> {
    await waitForWriteUnlock(documentName);
  }
}
