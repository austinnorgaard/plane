/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { Hocuspocus } from "@hocuspocus/server";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as Y from "yjs";
import { convertBase64StringToBinaryData, getBinaryDataFromDocumentEditorHTMLString } from "@plane/editor/lib";
import { REBASE_CONTENT_TYPE } from "@/fork-pages/pages.controller";
import { authHeaders, postRebase, startApp, TEST_KEY } from "./helpers";

const mockEnv = vi.hoisted(() => ({ LIVE_SERVER_SECRET_KEY: "" }));
vi.mock("@/env", () => ({ env: mockEnv }));

const PAGE = "0b9a3f0e-6a44-4d0f-9f0a-1f2f4a1f7a11";
const deferred = () => {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => (resolve = r));
  return { promise, resolve };
};
const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");
const base = () => b64(getBinaryDataFromDocumentEditorHTMLString("<p>old</p>", "Old"));

beforeEach(() => {
  process.env.PAGES_API_ENABLED = "1";
  mockEnv.LIVE_SERVER_SECRET_KEY = TEST_KEY;
});

describe("GET /fork/pages/:page_id/loaded", () => {
  let hocuspocus: Hocuspocus;
  let app: Awaited<ReturnType<typeof startApp>>;
  let loadGate = deferred();
  let storeGate = deferred();
  const onStore = vi.fn(async () => storeGate.promise);
  const onLoad = vi.fn(async () => {
    await loadGate.promise;
    return null;
  });
  const loaded = async (id = PAGE) => {
    const res = await fetch(`${app.base}/fork/pages/${id}/loaded`, { headers: authHeaders() });
    return { status: res.status, body: (await res.json()) as { loaded?: boolean } };
  };

  beforeAll(async () => {
    hocuspocus = new Hocuspocus({ quiet: true, debounce: 0, onLoadDocument: onLoad, onStoreDocument: onStore });
    app = await startApp(hocuspocus);
  });
  afterAll(() => app.close());

  it("400 for a non-UUID id", async () => {
    const statuses = await Promise.all(
      ["abc", "1234", "0b9a3f0e-6a44-4d0f-9f0a-1f2f4a1f7a1z"].map(async (id) => (await loaded(id)).status)
    );
    expect(statuses).toEqual([400, 400, 400]);
  });

  it("walks through unknown, loading, loaded, final-store and unloaded", async () => {
    expect(await loaded()).toEqual({ status: 200, body: { loaded: false } });

    // loading window: the document is registered only in loadingDocuments/documents while onLoadDocument runs
    const connecting = hocuspocus.openDirectConnection(PAGE, {});
    await vi.waitFor(() => expect(onLoad).toHaveBeenCalled());
    expect(hocuspocus.loadingDocuments.has(PAGE) || hocuspocus.documents.has(PAGE)).toBe(true);
    expect((await loaded()).body.loaded).toBe(true);

    loadGate.resolve();
    const connection = await connecting;
    expect(hocuspocus.loadingDocuments.has(PAGE)).toBe(false);
    expect(hocuspocus.documents.has(PAGE)).toBe(true);
    expect((await loaded()).body.loaded).toBe(true);

    // final-store window: the last connection is gone and the store has not resolved yet
    connection.document!.getXmlFragment("default").insert(0, [new Y.XmlText("x")]);
    const disconnecting = connection.disconnect();
    await vi.waitFor(() => expect(onStore).toHaveBeenCalled());
    expect(hocuspocus.documents.has(PAGE)).toBe(true);
    expect((await loaded()).body.loaded).toBe(true);

    storeGate.resolve();
    await disconnecting;
    await vi.waitFor(() => expect(hocuspocus.documents.has(PAGE)).toBe(false));
    expect((await loaded()).body.loaded).toBe(false);
  });

  it("reports loaded while only loadingDocuments knows the page (onCreateDocument window)", async () => {
    const id = "3c2b1a09-7777-4888-9999-aaaabbbbcccc";
    const gate = deferred();
    const slow = new Hocuspocus({ quiet: true, extensions: [{ onCreateDocument: async () => gate.promise }] });
    const slowApp = await startApp(slow);
    try {
      const connecting = slow.openDirectConnection(id, {});
      await vi.waitFor(() => expect(slow.loadingDocuments.has(id)).toBe(true));
      expect(slow.documents.has(id)).toBe(false);
      const res = await fetch(`${slowApp.base}/fork/pages/${id}/loaded`, { headers: authHeaders() });
      expect(await res.json()).toEqual({ loaded: true });
      gate.resolve();
      await (await connecting).disconnect();
    } finally {
      await slowApp.close();
    }
  });

  it("never creates a document or triggers a load or store", async () => {
    const other = "6f1c2d9a-1111-4222-8333-444455556666";
    const setSpy = vi.spyOn(hocuspocus.documents, "set");
    const loadSpy = vi.spyOn(hocuspocus, "createDocument");
    const loadsBefore = onLoad.mock.calls.length;
    const storesBefore = onStore.mock.calls.length;

    await loaded(other);
    await loaded(other);
    await postRebase(app.base, { base_binary: base(), description_html: "<p>n</p>", name: "N" });

    expect(setSpy).not.toHaveBeenCalled();
    expect(loadSpy).not.toHaveBeenCalled();
    expect(hocuspocus.documents.size).toBe(0);
    expect(hocuspocus.loadingDocuments.size).toBe(0);
    expect(onLoad.mock.calls.length).toBe(loadsBefore);
    expect(onStore.mock.calls.length).toBe(storesBefore);
  });
});

describe("POST /fork/pages/rebase", () => {
  let app: Awaited<ReturnType<typeof startApp>>;
  beforeAll(async () => {
    app = await startApp(new Hocuspocus({ quiet: true }));
  });
  afterAll(() => app.close());

  it("returns the rebased formats", async () => {
    const res = await postRebase(app.base, { base_binary: base(), description_html: "<p>new</p>", name: "New" });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      description_binary: string;
      description_html: string;
      description_json: object;
    };
    expect(body.description_html).toContain("new");
    expect(body.description_json).toBeTypeOf("object");
    const doc = new Y.Doc();
    Y.applyUpdate(doc, convertBase64StringToBinaryData(body.description_binary));
    expect(doc.getXmlFragment("title").length).toBeGreaterThan(0);
  });

  it("accepts a body larger than the global 100 KB json limit", async () => {
    const html = `<p>${"a".repeat(300 * 1024)}</p>`;
    const res = await postRebase(app.base, { base_binary: base(), description_html: html, name: null });
    expect(res.status).toBe(200);
  });

  it("413 above the 25 MB body limit", async () => {
    const res = await postRebase(app.base, { base_binary: base(), description_html: "a".repeat(26 * 1024 * 1024) });
    expect(res.status).toBe(413);
  });

  it("415 for another content type", async () => {
    const res = await fetch(`${app.base}/fork/pages/rebase`, {
      method: "POST",
      headers: authHeaders({ "content-type": "application/json" }),
      body: JSON.stringify({ base_binary: base(), name: "x" }),
    });
    expect(res.status).toBe(415);
  });

  it.each([
    ["invalid json", "{nope"],
    ["missing base_binary", { name: "x" }],
    ["empty base_binary", { base_binary: "", name: "x" }],
    ["non-base64 base_binary", { base_binary: "not base64!!", name: "x" }],
    ["neither html nor name", { base_binary: "AAA=" }],
    ["both null", { base_binary: "AAA=", description_html: null, name: null }],
    ["wrong types", { base_binary: "AAA=", name: 5 }],
  ])("400 for %s", async (_n, body) => {
    expect((await postRebase(app.base, body)).status).toBe(400);
  });

  it("400 when base_binary decodes to more than 10 MB", async () => {
    const tooBig = Buffer.alloc(10 * 1024 * 1024 + 3, 1).toString("base64");
    expect((await postRebase(app.base, { base_binary: tooBig, name: "x" })).status).toBe(400);
  });

  it("400 when base_binary is valid base64 but not a document state", async () => {
    const res = await postRebase(app.base, { base_binary: b64(new Uint8Array([255, 255, 255, 9])), name: "x" });
    expect(res.status).toBe(400);
  });

  it.each([
    ["characters outside the base64 alphabet", "AAA!AAA="],
    ["a length that is not a multiple of 4", "AAAAA"],
    ["misplaced padding", "AA=A"],
  ])("400 with the base_binary issue path for %s", async (_n, value) => {
    const res = await postRebase(app.base, { base_binary: value, name: "x" });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string; issues: Array<{ path: string }> };
    expect(body.error).toBe("Validation error");
    expect(body.issues.map((issue) => issue.path)).toEqual(["base_binary"]);
  });

  it("does not echo submitted values in validation errors", async () => {
    const res = await postRebase(app.base, { base_binary: "SECRET-VALUE!!", name: "x" });
    expect(await res.text()).not.toContain("SECRET-VALUE");
  });

  it("does not log html, binaries or the key when a request fails", async () => {
    const spies = (["log", "info", "warn", "error"] as const).map((m) =>
      vi.spyOn(console, m).mockImplementation(() => {})
    );
    await postRebase(app.base, {
      base_binary: b64(new Uint8Array([255, 255, 255, 9])),
      description_html: "<p>PRIVATE-HTML</p>",
      name: "x",
    });
    await postRebase(app.base, { base_binary: "SECRET-BIN!!", name: "x" });
    await fetch(`${app.base}/fork/pages/rebase`, {
      method: "POST",
      headers: { "content-type": REBASE_CONTENT_TYPE, "live-server-secret-key": "WRONG-KEY-VALUE" },
      body: "{}",
    });
    const logged = spies
      .flatMap((s) => s.mock.calls)
      .map((c) => JSON.stringify(c))
      .join("\n");
    spies.forEach((s) => s.mockRestore());
    for (const secret of ["PRIVATE-HTML", "SECRET-BIN", "WRONG-KEY-VALUE", TEST_KEY])
      expect(logged).not.toContain(secret);
  });
});
