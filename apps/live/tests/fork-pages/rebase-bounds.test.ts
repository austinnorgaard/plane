/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { Hocuspocus } from "@hocuspocus/server";
import { monitorEventLoopDelay } from "node:perf_hooks";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { getBinaryDataFromDocumentEditorHTMLString } from "@plane/editor/lib";
import { getRebaseWorkerCount, stopRebaseWorkers, waitForRebaseWorker } from "@/fork-pages/rebase-runner";
import { authHeaders, postRebase, startApp, TEST_KEY } from "./helpers";

const mockEnv = vi.hoisted(() => ({ LIVE_SERVER_SECRET_KEY: "" }));
vi.mock("@/env", () => ({ env: mockEnv }));

const PAGE = "0b9a3f0e-6a44-4d0f-9f0a-1f2f4a1f7a11";
const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");
const base = () => b64(getBinaryDataFromDocumentEditorHTMLString("<p>old</p>", "Old"));

// html of about `bytes` bytes made of many small formatted paragraphs (the shape that is slow to convert)
const htmlOfSize = (bytes: number) => {
  const unit = "<p>line <strong>bold</strong> and <em>italic</em> text</p>";
  return unit.repeat(Math.ceil(bytes / unit.length));
};

let app: Awaited<ReturnType<typeof startApp>>;

// Generous on purpose: covers a cold worker load on a loaded machine. Assertions are not relaxed.
const COLD_START_TIMEOUT_MS = 120_000;

beforeAll(async () => {
  mockEnv.LIVE_SERVER_SECRET_KEY = TEST_KEY;
  process.env.PAGES_API_ENABLED = "1";
  app = await startApp(new Hocuspocus({ quiet: true }));
  // A cold worker needs about 2 s (much more under CPU load) to load the editor modules; the tests
  // below must not pay that inside their own timing windows.
  await waitForRebaseWorker();
}, COLD_START_TIMEOUT_MS);
afterAll(async () => {
  await app.close();
  await stopRebaseWorkers();
});
beforeEach(() => {
  process.env.PAGES_API_ENABLED = "1";
  mockEnv.LIVE_SERVER_SECRET_KEY = TEST_KEY;
});
afterEach(() => {
  delete process.env.PAGES_REBASE_MAX_HTML_BYTES;
  delete process.env.PAGES_REBASE_TIMEOUT_MS;
  delete process.env.PAGES_REBASE_MAX_CONCURRENCY;
});

describe("html size cap", () => {
  it("answers 413 above the cap and 200 at the cap, counting bytes not characters", async () => {
    process.env.PAGES_REBASE_MAX_HTML_BYTES = "1000";
    const at = `<p>${"a".repeat(1000 - 7)}</p>`;
    expect(Buffer.byteLength(at)).toBe(1000);
    expect((await postRebase(app.base, { base_binary: base(), description_html: at })).status).toBe(200);

    const over = `<p>${"a".repeat(1000 - 6)}</p>`;
    const res = await postRebase(app.base, { base_binary: base(), description_html: over });
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "description_html too large", max_bytes: 1000 });

    // 507 characters, 1007 bytes: fewer characters than the cap, more bytes
    const multibyte = `<p>${"é".repeat(500)}</p>`;
    expect(multibyte.length).toBeLessThan(1000);
    expect((await postRebase(app.base, { base_binary: base(), description_html: multibyte })).status).toBe(413);
  });

  it("uses a default cap of 512 KiB", async () => {
    const res = await postRebase(app.base, { base_binary: base(), description_html: htmlOfSize(524288 + 100) });
    expect(res.status).toBe(413);
    expect(((await res.json()) as { max_bytes: number }).max_bytes).toBe(524288);
  });

  it("rejects a body over the raw cap before parsing it", async () => {
    process.env.PAGES_REBASE_MAX_HTML_BYTES = "1000";
    const res = await postRebase(app.base, `{"base_binary":"${"A".repeat(16 * 1024 * 1024)}"}`);
    expect(res.status).toBe(413);
  });

  it("still answers 401 before reading an oversize body", async () => {
    const res = await postRebase(app.base, { base_binary: base(), description_html: "<p>x</p>" }, {});
    expect(res.status).toBe(401);
  });
});

describe("time budget", () => {
  it(
    "answers 503 when the conversion exceeds the budget, stops the worker, and recovers",
    async () => {
      process.env.PAGES_REBASE_MAX_HTML_BYTES = "4000000";
      process.env.PAGES_REBASE_TIMEOUT_MS = "100";
      await waitForRebaseWorker();
      const workersBefore = getRebaseWorkerCount();
      const started = Date.now();
      const res = await postRebase(app.base, { base_binary: base(), description_html: htmlOfSize(1_000_000) });
      expect(res.status).toBe(503);
      expect(Date.now() - started).toBeLessThan(3000);

      // the thread is really stopped (the conversion alone would run for seconds more), and the next
      // request is served by a fresh worker
      await vi.waitFor(() => expect(getRebaseWorkerCount()).toBeLessThan(workersBefore), { timeout: 10_000 });
      process.env.PAGES_REBASE_TIMEOUT_MS = "30000";
      // the stopped worker is replaced by a new one; load it before the timed request
      await waitForRebaseWorker();
      const ok = await postRebase(app.base, { base_binary: base(), description_html: "<p>after</p>" });
      expect(ok.status).toBe(200);
    },
    COLD_START_TIMEOUT_MS
  );

  it(
    "answers 503 with Retry-After at once when every worker is busy",
    async () => {
      process.env.PAGES_REBASE_MAX_HTML_BYTES = "4000000";
      process.env.PAGES_REBASE_MAX_CONCURRENCY = "1";
      process.env.PAGES_REBASE_TIMEOUT_MS = "30000";
      // start from exactly one loaded worker, then occupy it
      await stopRebaseWorkers();
      await vi.waitFor(() => expect(getRebaseWorkerCount()).toBe(0), { timeout: 10_000 });
      await waitForRebaseWorker();
      expect((await postRebase(app.base, { base_binary: base(), description_html: "<p>warm</p>" })).status).toBe(200);
      const slow = postRebase(app.base, { base_binary: base(), description_html: htmlOfSize(400_000) });
      await new Promise((r) => setTimeout(r, 100));
      const refused = await postRebase(app.base, { base_binary: base(), description_html: "<p>x</p>" });
      expect(refused.status).toBe(503);
      expect(refused.headers.get("retry-after")).toBe("5");
      expect((await slow).status).toBe(200);
    },
    COLD_START_TIMEOUT_MS
  );
});

describe("event loop", () => {
  // Probes the server with cheap requests for `ms` (or until `until` settles); returns each latency.
  const probe = async (ms: number, until?: Promise<unknown>) => {
    let finished = false;
    void until?.then(() => (finished = true));
    const latencies: number[] = [];
    const end = Date.now() + ms;
    // sequential polling is the point: each probe measures one request
    // oxlint-disable-next-line no-unmodified-loop-condition
    while (until ? !finished : Date.now() < end) {
      const t = performance.now();
      // oxlint-disable-next-line no-await-in-loop
      const res = await fetch(`${app.base}/fork/pages/${PAGE}/loaded`, { headers: authHeaders() });
      expect(res.status).toBe(200);
      latencies.push(performance.now() - t);
      // oxlint-disable-next-line no-await-in-loop
      await new Promise((r) => setTimeout(r, 20));
    }
    return latencies;
  };

  it(
    "keeps answering other requests while a large conversion runs",
    async () => {
      process.env.PAGES_REBASE_MAX_HTML_BYTES = "4000000";
      process.env.PAGES_REBASE_TIMEOUT_MS = "60000";
      // warm the worker so the measured window is the conversion itself
      expect((await postRebase(app.base, { base_binary: base(), description_html: "<p>warm</p>" })).status).toBe(200);

      // Baseline on the same, idle server in the same window of machine load: on a busy machine the
      // process itself is starved of CPU by other processes, which shows up as loop delay and request
      // latency too. The bounds below are margins ABOVE this baseline, so they measure what the
      // conversion adds (a blocked loop would add seconds), not the machine's load.
      const idleLoop = monitorEventLoopDelay({ resolution: 5 });
      idleLoop.enable();
      const idleLatencies = await probe(2000);
      idleLoop.disable();
      const baselineLagMs = idleLoop.max / 1e6;
      const baselineWorstMs = Math.max(...idleLatencies);

      const histogram = monitorEventLoopDelay({ resolution: 5 });
      histogram.enable();
      const started = Date.now();
      const big = postRebase(app.base, { base_binary: base(), description_html: htmlOfSize(1_000_000) }).then((r) => ({
        status: r.status,
        doneAt: Date.now(),
      }));
      const latencies = await probe(0, big);
      histogram.disable();
      const result = await big;
      const conversionMs = result.doneAt - started;

      expect(result.status).toBe(200);
      expect(conversionMs).toBeGreaterThan(1000); // the conversion was long enough to matter
      expect(latencies.length).toBeGreaterThan(10);
      const worst = Math.max(...latencies);
      const maxLagMs = histogram.max / 1e6;
      console.log(
        `rebase 1 MB: ${conversionMs} ms; ${latencies.length} cheap requests, worst ${worst.toFixed(0)} ms ` +
          `(idle ${baselineWorstMs.toFixed(0)}); event loop delay max ${maxLagMs.toFixed(0)} ms (idle ${baselineLagMs.toFixed(0)})`
      );
      expect(worst).toBeLessThan(baselineWorstMs + 250);
      // main-thread cost of the large body and reply (parse, encode) is linear and small next to the conversion
      expect(maxLagMs).toBeLessThan(baselineLagMs + 750);
    },
    COLD_START_TIMEOUT_MS
  );
});
