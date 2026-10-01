/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll } from "vitest";
import { setRebaseWorkerUrl, stopRebaseWorkers } from "@/fork-pages/rebase-runner";

// Run the rebase worker from the bundle built by tests/global-setup.ts.
export const BUILT_WORKER_URL = pathToFileURL(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../node_modules/.cache/rebase-worker-test/rebase.worker.mjs"
  )
);
setRebaseWorkerUrl(BUILT_WORKER_URL);
afterAll(() => stopRebaseWorkers());
