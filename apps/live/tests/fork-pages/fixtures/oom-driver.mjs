// SPDX-License-Identifier: AGPL-3.0-only
//
// Run by rebase-memory.test.ts in a child node process WITHOUT NODE_OPTIONS (a --max-old-space-size
// there overrides the per-worker limit). Uses the real runner and worker from the bundle built in
// tests/global-setup.ts: a base state too large for the given heap must fail with an out-of-memory
// error, and the next, ordinary job must still succeed on a fresh worker.
import { pathToFileURL } from "node:url";
import path from "node:path";
import * as Y from "yjs";
import { getBinaryDataFromDocumentEditorHTMLString } from "@plane/editor/lib";

const bundle = path.resolve(import.meta.dirname, "../../../node_modules/.cache/rebase-worker-test");
const { runRebase, setRebaseWorkerUrl, getRebaseWorkerCount, stopRebaseWorkers, waitForRebaseWorker } = await import(
  pathToFileURL(path.join(bundle, "rebase-runner.mjs")).href
);
setRebaseWorkerUrl(pathToFileURL(path.join(bundle, "rebase.worker.mjs")));
process.env.PAGES_REBASE_WORKER_MAX_MB = process.argv[2] ?? "64";

const doc = new Y.Doc();
Y.applyUpdate(doc, getBinaryDataFromDocumentEditorHTMLString("<p>old</p>", "Old"));
const junk = doc.getMap("junk");
doc.transact(() => {
  for (let i = 0; i < Number(process.argv[3] ?? 100000); i += 1) junk.set(`k${i}`, i);
});
const heavy = Y.encodeStateAsUpdate(doc);
const small = getBinaryDataFromDocumentEditorHTMLString("<p>old</p>", "Old");
const options = { timeoutMs: 120000, maxConcurrency: 1 };

const out = {};
// a cold worker needs seconds to load, much more on a loaded machine: load it before the timed part
await waitForRebaseWorker();
try {
  await runRebase(
    { baseBinaryBase64: Buffer.from(heavy).toString("base64"), descriptionHtml: "<p>x</p>", name: null },
    options
  );
  out.heavy = "ok";
} catch (error) {
  out.heavy = error.name;
}
const deadline = Date.now() + 20000;
// polling for the thread exit is sequential by nature
// oxlint-disable-next-line no-await-in-loop
while (getRebaseWorkerCount() !== 0 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
out.workersAfterFailure = getRebaseWorkerCount();
await waitForRebaseWorker();
try {
  const result = await runRebase(
    { baseBinaryBase64: Buffer.from(small).toString("base64"), descriptionHtml: "<p>after</p>", name: null },
    options
  );
  out.after = JSON.parse(result).description_html.includes("after") ? "ok" : "wrong";
} catch (error) {
  out.after = error.name;
}
await stopRebaseWorkers();
console.log(JSON.stringify(out));
