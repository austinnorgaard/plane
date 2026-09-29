/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { Hocuspocus } from "@hocuspocus/server";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { authHeaders, postRebase, startApp, TEST_KEY } from "./helpers";

const compare = vi.hoisted(() => ({ calls: [] as Array<[number, number]> }));
vi.mock("crypto", async (importOriginal) => {
  const actual = await importOriginal<typeof import("crypto")>();
  return {
    ...actual,
    timingSafeEqual: (a: NodeJS.ArrayBufferView, b: NodeJS.ArrayBufferView) => {
      compare.calls.push([a.byteLength, b.byteLength]);
      return actual.timingSafeEqual(a, b);
    },
  };
});

const mockEnv = vi.hoisted(() => ({ LIVE_SERVER_SECRET_KEY: "" }));
vi.mock("@/env", () => ({ env: mockEnv }));

const PAGE = "0b9a3f0e-6a44-4d0f-9f0a-1f2f4a1f7a11";
let app: Awaited<ReturnType<typeof startApp>>;

const get = (headers: Record<string, string>) => fetch(`${app.base}/fork/pages/${PAGE}/loaded`, { headers });
const rebaseBody = { base_binary: "AAA=", name: "x" };

beforeAll(async () => {
  app = await startApp(new Hocuspocus({ quiet: true }));
});
afterAll(() => app.close());
beforeEach(() => {
  process.env.PAGES_API_ENABLED = "1";
  mockEnv.LIVE_SERVER_SECRET_KEY = TEST_KEY;
});

describe("pages access guard", () => {
  it.each([
    ["GET loaded", () => get(authHeaders())],
    ["POST rebase", () => postRebase(app.base, rebaseBody)],
  ])("%s: 404 when the feature flag is not 1, before any other check", async (_n, call) => {
    for (const flag of [undefined, "0", "true", ""]) {
      if (flag === undefined) delete process.env.PAGES_API_ENABLED;
      else process.env.PAGES_API_ENABLED = flag;
      mockEnv.LIVE_SERVER_SECRET_KEY = ""; // would be 503 if the flag were checked second
      // sequential on purpose: each pass changes process-wide state
      // oxlint-disable-next-line no-await-in-loop
      expect((await call()).status).toBe(404);
    }
  });

  it.each(["", "change-this-key-on-deployment"])("503 when the configured key is %j", async (key) => {
    mockEnv.LIVE_SERVER_SECRET_KEY = key;
    // even with forwarded headers and a header equal to the placeholder, 503 wins
    const res = await get({ "live-server-secret-key": key, "x-forwarded-for": "proxy.example" });
    expect(res.status).toBe(503);
    expect((await postRebase(app.base, rebaseBody, { "live-server-secret-key": key })).status).toBe(503);
  });

  it.each(["x-forwarded-for", "x-forwarded-host"])(
    "403 when %s is present, even with a correct key",
    async (header) => {
      expect((await get(authHeaders({ [header]: "example" }))).status).toBe(403);
      expect((await postRebase(app.base, rebaseBody, authHeaders({ [header]: "example" }))).status).toBe(403);
      // 403 wins over a wrong key
      expect((await get({ "live-server-secret-key": "wrong", [header]: "example" })).status).toBe(403);
    }
  );

  it.each([
    ["missing", {}],
    ["wrong, same length", { "live-server-secret-key": "x".repeat(TEST_KEY.length) }],
    ["wrong length, shorter", { "live-server-secret-key": "short" }],
    ["wrong length, longer", { "live-server-secret-key": TEST_KEY + "extra" }],
    ["empty", { "live-server-secret-key": "" }],
  ])("401 for a %s key", async (_n, headers) => {
    expect((await get(headers as Record<string, string>)).status).toBe(401);
    expect((await postRebase(app.base, rebaseBody, headers as Record<string, string>)).status).toBe(401);
  });

  it("compares equal-length sha256 digests, so a wrong-length key never reaches a raw comparison", async () => {
    compare.calls.length = 0;
    await get({ "live-server-secret-key": "short" });
    expect(compare.calls).toEqual([[32, 32]]);
  });

  it("lets a correct key through", async () => {
    expect((await get(authHeaders())).status).toBe(200);
  });

  it("does not read the request body for a caller that fails the guard", async () => {
    const res = await postRebase(app.base, "{not json", {});
    expect(res.status).toBe(401);
  });
});
