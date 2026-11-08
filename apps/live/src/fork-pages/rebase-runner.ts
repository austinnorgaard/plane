/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

// Runs the rebase conversion in worker threads so the (synchronous, superlinear) html conversion never
// blocks the live event loop.
//
// - A small pool of long-lived workers: loading the editor modules takes about two seconds, so a worker
//   is reused for later jobs instead of being started per request.
// - A job that exceeds its time budget has its worker terminated (the thread really stops) and the
//   caller gets RebaseTimeoutError. The budget starts when the job is handed to a loaded worker.
// - At most `maxConcurrency` workers exist; a call that finds all of them busy is refused at once
//   (RebaseBusyError), there is no queue. A terminated worker keeps its slot until its thread has exited.

import { existsSync } from "node:fs";
import { Worker } from "node:worker_threads";
import { InvalidBaseStateError } from "./rebase";
import type { TWorkerReply } from "./rebase.worker";

export class RebaseTimeoutError extends Error {
  constructor() {
    super("rebase exceeded its time budget");
    this.name = "RebaseTimeoutError";
  }
}

export class RebaseBusyError extends Error {
  constructor() {
    super("too many rebase conversions in progress");
    this.name = "RebaseBusyError";
  }
}

export class RebaseWorkerError extends Error {
  constructor(name: string) {
    super("rebase worker failed");
    this.name = name;
  }
}

export type TRunRebaseOptions = {
  timeoutMs: number;
  maxConcurrency: number;
};

// How long a new worker may take to load before the job waiting for it is failed.
const STARTUP_TIMEOUT_MS = 10_000;

export type TRebaseWorkerInput = {
  /** the stored document state, base64 (decoded inside the worker) */
  baseBinaryBase64: string;
  descriptionHtml: string | null;
  name: string | null;
};

type TJob = { resolve: (json: string) => void; reject: (error: Error) => void; input: TRebaseWorkerInput };
type TSlot = {
  worker: Worker;
  state: "starting" | "idle" | "busy" | "dying";
  job?: TJob;
  timer?: NodeJS.Timeout;
  timeoutMs: number;
  readyWaiters: { resolve: () => void; reject: (error: Error) => void }[];
};

const DEFAULT_WORKER_MAX_MB = 256;

// Heap cap of one worker (PAGES_REBASE_WORKER_MAX_MB), read when a worker is started. A worker that
// exceeds it is stopped by node and the call fails; the pool starts a new worker for the next call.
export const getRebaseWorkerMaxMb = (): number => {
  const parsed = Number.parseInt(process.env.PAGES_REBASE_WORKER_MAX_MB ?? "", 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : DEFAULT_WORKER_MAX_MB;
};

const slots = new Set<TSlot>();
let workerUrlOverride: URL | undefined;

/** Test hook: run this worker script instead of the bundled one (undefined restores the default). */
export const setRebaseWorkerUrl = (url: URL | undefined) => {
  workerUrlOverride = url;
};

/** Number of worker threads that exist (idle, busy or still stopping). */
export const getRebaseWorkerCount = () => slots.size;

/** Stops every worker. For shutdown and tests. */
export const stopRebaseWorkers = async () => {
  await Promise.all([...slots].map((slot) => slot.worker.terminate()));
};

// The bundled server ships the worker next to itself (dist/fork-pages/rebase.worker.mjs).
const resolveWorkerUrl = (): URL => {
  const url = new URL("./fork-pages/rebase.worker.mjs", import.meta.url);
  if (!existsSync(url)) throw new RebaseWorkerError("WorkerScriptMissing");
  return url;
};

const failJob = (slot: TSlot, error: Error) => {
  clearTimeout(slot.timer);
  const job = slot.job;
  slot.job = undefined;
  job?.reject(error);
};

const kill = (slot: TSlot, error: Error) => {
  slot.state = "dying";
  failJob(slot, error);
  void slot.worker.terminate();
};

const dispatch = (slot: TSlot) => {
  const job = slot.job;
  if (!job) return;
  slot.state = "busy";
  slot.worker.ref();
  slot.timer = setTimeout(() => kill(slot, new RebaseTimeoutError()), slot.timeoutMs);
  // worker thread message, not window.postMessage: there is no target origin
  // oxlint-disable-next-line unicorn/require-post-message-target-origin
  slot.worker.postMessage(job.input);
};

const startSlot = (): TSlot => {
  const worker = new Worker(workerUrlOverride ?? resolveWorkerUrl(), {
    resourceLimits: { maxOldGenerationSizeMb: getRebaseWorkerMaxMb() },
  });
  const slot: TSlot = { worker, state: "starting", timeoutMs: 0, readyWaiters: [] };
  slots.add(slot);

  worker.on("message", (reply: TWorkerReply) => {
    if (slot.state === "dying") return;
    if (reply.type === "ready") {
      clearTimeout(slot.timer);
      if (slot.job) dispatch(slot);
      else {
        slot.state = "idle";
        worker.unref();
      }
      slot.readyWaiters.splice(0).forEach((waiter) => waiter.resolve());
      return;
    }
    const job = slot.job;
    clearTimeout(slot.timer);
    slot.job = undefined;
    slot.state = "idle";
    worker.unref();
    if (!job) return;
    if (reply.ok) job.resolve(reply.json);
    else job.reject(reply.kind === "invalid_base" ? new InvalidBaseStateError() : new RebaseWorkerError(reply.name));
  });
  worker.on("error", (error) => {
    slot.state = "dying";
    // an out-of-memory stop arrives here (ERR_WORKER_OUT_OF_MEMORY); only the error code is kept
    const code = (error as { code?: string } | undefined)?.code;
    const failure = new RebaseWorkerError(code ?? (error instanceof Error ? error.name : "unknown"));
    failJob(slot, failure);
    slot.readyWaiters.splice(0).forEach((waiter) => waiter.reject(failure));
  });
  worker.on("exit", () => {
    slot.state = "dying";
    slots.delete(slot);
    failJob(slot, new RebaseWorkerError("WorkerExited"));
    slot.readyWaiters.splice(0).forEach((waiter) => waiter.reject(new RebaseWorkerError("WorkerExited")));
  });
  worker.unref();
  return slot;
};

/** Resolves when a loaded worker is available (starting one if none exists). Rejects if it fails to start. */
export const waitForRebaseWorker = (): Promise<void> =>
  new Promise<void>((resolve, reject) => {
    try {
      const slot =
        [...slots].find((candidate) => candidate.state === "idle" || candidate.state === "starting") ?? startSlot();
      if (slot.state === "idle") resolve();
      else {
        // an unref'd starting worker would let the process exit while the caller waits for it
        slot.worker.ref();
        slot.readyWaiters.push({ resolve, reject });
      }
    } catch (error) {
      reject(error instanceof Error ? error : new RebaseWorkerError("WorkerStartFailed"));
    }
  });

/** Starts one worker ahead of the first request so that request does not pay the load time. */
export const prewarmRebaseWorker = () => {
  try {
    if (slots.size === 0) startSlot();
  } catch {
    // no worker script (for example when running from source); the first real call reports it
  }
};

/** Resolves with the answer of the route, already serialised as json. */
export const runRebase = (input: TRebaseWorkerInput, options: TRunRebaseOptions): Promise<string> =>
  new Promise<string>((resolve, reject) => {
    let slot = [...slots].find(
      (candidate) => candidate.state === "idle" || (candidate.state === "starting" && !candidate.job)
    );
    if (!slot) {
      if (slots.size >= options.maxConcurrency) {
        reject(new RebaseBusyError());
        return;
      }
      try {
        slot = startSlot();
      } catch (error) {
        reject(error instanceof RebaseWorkerError ? error : new RebaseWorkerError("WorkerStartFailed"));
        return;
      }
    }
    slot.job = { resolve, reject, input };
    slot.timeoutMs = options.timeoutMs;
    if (slot.state === "idle") dispatch(slot);
    else {
      const starting = slot;
      starting.worker.ref();
      starting.timer = setTimeout(
        () => kill(starting, new RebaseWorkerError("WorkerStartTimeout")),
        STARTUP_TIMEOUT_MS
      );
    }
  });
