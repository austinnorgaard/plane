/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

// Worker-thread entry for the rebase conversion (see rebase-runner.ts). Handles one job at a time and
// tells the parent when its (slow) module loading is done.

import { parentPort } from "node:worker_threads";
import { InvalidBaseStateError, rebase } from "./rebase";
import type { TRebaseWorkerInput } from "./rebase-runner";

export type TWorkerReply =
  | { type: "ready" }
  | { type: "result"; ok: true; json: string }
  | { type: "result"; ok: false; kind: "invalid_base" | "error"; name: string };

const send = (reply: TWorkerReply) => parentPort?.postMessage(reply);

parentPort?.on("message", (input: TRebaseWorkerInput) => {
  try {
    // Decoding the base state and serialising the answer happen here too, so the main thread only
    // forwards one string (copying large nested objects between threads costs main-thread time).
    const result = rebase({
      baseBinary: new Uint8Array(Buffer.from(input.baseBinaryBase64, "base64")),
      descriptionHtml: input.descriptionHtml,
      name: input.name,
    });
    send({ type: "result", ok: true, json: JSON.stringify(result) });
  } catch (error) {
    if (error instanceof InvalidBaseStateError) {
      send({ type: "result", ok: false, kind: "invalid_base", name: error.name });
    } else {
      send({ type: "result", ok: false, kind: "error", name: error instanceof Error ? error.name : "unknown" });
    }
  }
});

send({ type: "ready" });
