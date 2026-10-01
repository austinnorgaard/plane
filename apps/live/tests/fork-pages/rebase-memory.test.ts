/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const run = promisify(execFile);
const driver = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "fixtures/oom-driver.mjs");

// A --max-old-space-size in NODE_OPTIONS overrides the per-worker heap limit, so the driver runs in a
// child process without it (the shipped container sets none).
const { NODE_OPTIONS: _ignored, ...cleanEnv } = process.env;

describe("worker memory limit", () => {
  it("stops a worker that exceeds PAGES_REBASE_WORKER_MAX_MB and the pool recovers", async () => {
    const { stdout } = await run(process.execPath, [driver, "64", "100000"], { env: cleanEnv, timeout: 110_000 });
    const out = JSON.parse(stdout.trim().split("\n").pop() ?? "{}") as Record<string, unknown>;
    expect(out).toEqual({ heavy: "ERR_WORKER_OUT_OF_MEMORY", workersAfterFailure: 0, after: "ok" });
  }, 120_000);

  it("the same input fits in the default limit of 256 MB", async () => {
    const { stdout } = await run(process.execPath, [driver, "256", "100000"], { env: cleanEnv, timeout: 110_000 });
    const out = JSON.parse(stdout.trim().split("\n").pop() ?? "{}") as Record<string, unknown>;
    expect(out.heavy).toBe("ok");
  }, 120_000);
});
