/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

// The rebase worker thread runs plain node (no vitest transform), so the tests run it from a bundle
// built here once. The bundle lives under node_modules/.cache so its imports resolve like dist/ does.
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "tsdown";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const WORKER_BUNDLE_DIR = path.join(root, "node_modules", ".cache", "rebase-worker-test");

export default async function setup() {
  await build({
    config: false,
    cwd: root,
    entry: { "rebase.worker": "src/fork-pages/rebase.worker.ts" },
    outDir: WORKER_BUNDLE_DIR,
    format: ["esm"],
    dts: false,
    clean: true,
    sourcemap: false,
    silent: true,
  });
}
