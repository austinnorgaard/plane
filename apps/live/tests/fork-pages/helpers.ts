/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import type { Server } from "http";
import type { AddressInfo } from "net";
import type { Hocuspocus } from "@hocuspocus/server";
import express from "express";
import { registerController } from "@plane/decorators";
import { PagesController, REBASE_CONTENT_TYPE } from "@/fork-pages/pages.controller";

export const TEST_KEY = "test-secret-key-0123456789";

// Mirrors the real server: global 100 KB json parser first, then the controller routes.
export const startApp = async (hocuspocus: Hocuspocus) => {
  const app = express();
  app.use(express.json());
  const router = express.Router();
  registerController(router, PagesController, [hocuspocus]);
  app.use(router);
  const server: Server = await new Promise((resolve) => {
    const s = app.listen(0, "localhost", () => resolve(s));
  });
  const { address, port } = server.address() as AddressInfo;
  const base = `http://${address.includes(":") ? `[${address}]` : address}:${port}`;
  return { base, close: () => new Promise<void>((resolve) => server.close(() => resolve())) };
};

export const authHeaders = (extra: Record<string, string> = {}) => ({ "live-server-secret-key": TEST_KEY, ...extra });

export const postRebase = (base: string, body: unknown, headers: Record<string, string> = authHeaders()) =>
  fetch(`${base}/fork/pages/rebase`, {
    method: "POST",
    headers: { "content-type": REBASE_CONTENT_TYPE, ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
