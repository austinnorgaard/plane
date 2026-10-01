/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

// Worker-thread entry for the rebase conversion (see rebase-runner.ts). Handles one job at a time and
// tells the parent when its (slow) module loading is done.

import { parentPort } from "node:worker_threads";
import { InvalidBaseStateError, rebase } from "./rebase";
import type { TRebaseInput, TRebaseResult } from "./rebase";

export type TWorkerReply =
  | { type: "ready" }
  | { type: "result"; ok: true; result: TRebaseResult }
  | { type: "result"; ok: false; kind: "invalid_base" | "error"; name: string };

const send = (reply: TWorkerReply) => parentPort?.postMessage(reply);

parentPort?.on("message", (input: TRebaseInput) => {
  try {
    send({ type: "result", ok: true, result: rebase(input) });
  } catch (error) {
    if (error instanceof InvalidBaseStateError) {
      send({ type: "result", ok: false, kind: "invalid_base", name: error.name });
    } else {
      send({ type: "result", ok: false, kind: "error", name: error instanceof Error ? error.name : "unknown" });
    }
  }
});

send({ type: "ready" });
