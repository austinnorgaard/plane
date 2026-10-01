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
import type { TRebaseInput, TRebaseResult } from "./rebase";
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

type TJob = { resolve: (result: TRebaseResult) => void; reject: (error: Error) => void; input: TRebaseInput };
type TSlot = {
  worker: Worker;
  state: "starting" | "idle" | "busy" | "dying";
  job?: TJob;
  timer?: NodeJS.Timeout;
  timeoutMs: number;
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
  const worker = new Worker(workerUrlOverride ?? resolveWorkerUrl());
  const slot: TSlot = { worker, state: "starting", timeoutMs: 0 };
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
      return;
    }
    const job = slot.job;
    clearTimeout(slot.timer);
    slot.job = undefined;
    slot.state = "idle";
    worker.unref();
    if (!job) return;
    if (reply.ok) job.resolve(reply.result);
    else job.reject(reply.kind === "invalid_base" ? new InvalidBaseStateError() : new RebaseWorkerError(reply.name));
  });
  worker.on("error", (error) => {
    slot.state = "dying";
    failJob(slot, new RebaseWorkerError(error instanceof Error ? error.name : "unknown"));
  });
  worker.on("exit", () => {
    slot.state = "dying";
    slots.delete(slot);
    failJob(slot, new RebaseWorkerError("WorkerExited"));
  });
  worker.unref();
  return slot;
};

/** Starts one worker ahead of the first request so that request does not pay the load time. */
export const prewarmRebaseWorker = () => {
  try {
    if (slots.size === 0) startSlot();
  } catch {
    // no worker script (for example when running from source); the first real call reports it
  }
};

export const runRebase = (input: TRebaseInput, options: TRunRebaseOptions): Promise<TRebaseResult> =>
  new Promise<TRebaseResult>((resolve, reject) => {
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
