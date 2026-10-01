/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import type { Hocuspocus } from "@hocuspocus/server";
import express from "express";
import type { NextFunction, Request, RequestHandler, Response } from "express";
import { z } from "zod";
import { Controller, Get, Middleware, Post } from "@plane/decorators";
import { logger } from "@plane/logger";
import { requirePagesApiAccess } from "./auth";
import { InvalidBaseStateError } from "./rebase";
import { prewarmRebaseWorker, RebaseBusyError, RebaseTimeoutError, runRebase } from "./rebase-runner";

export const REBASE_CONTENT_TYPE = "application/vnd.plane-fork.rebase+json";
const MAX_BASE_BINARY_BYTES = 10 * 1024 * 1024;
// base64 length of the largest allowed binary (4 chars per 3 bytes, padded)
const MAX_BASE_BINARY_CHARS = Math.ceil(MAX_BASE_BINARY_BYTES / 3) * 4;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

const pageIdSchema = z.string().uuid();

const rebaseBodySchema = z
  .object({
    base_binary: z
      .string()
      .min(1)
      .max(MAX_BASE_BINARY_CHARS)
      .refine((value) => value.length % 4 === 0 && BASE64_PATTERN.test(value), "must be base64"),
    description_html: z.string().nullable().optional(),
    name: z.string().nullable().optional(),
  })
  .refine((body) => body.description_html != null || body.name != null, "description_html or name is required");

// Limits of the rebase route, read per request from the environment (names and defaults in
// fork/deploy/README.fork). The html default is twice the API default, as headroom.
const DEFAULT_MAX_HTML_BYTES = 524288;
const DEFAULT_TIMEOUT_MS = 8000;
const DEFAULT_MAX_CONCURRENCY = 2;
const readPositiveInt = (name: string, fallback: number): number => {
  const parsed = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
};
export const getRebaseLimits = () => ({
  maxHtmlBytes: readPositiveInt("PAGES_REBASE_MAX_HTML_BYTES", DEFAULT_MAX_HTML_BYTES),
  timeoutMs: readPositiveInt("PAGES_REBASE_TIMEOUT_MS", DEFAULT_TIMEOUT_MS),
  maxConcurrency: readPositiveInt("PAGES_REBASE_MAX_CONCURRENCY", DEFAULT_MAX_CONCURRENCY),
});
// Raw body cap: the base64 binary, plus the html with worst case json escaping (6 bytes per
// byte), plus room for the name and the json framing.
const getRebaseBodyLimit = () => MAX_BASE_BINARY_CHARS + 6 * getRebaseLimits().maxHtmlBytes + 1024 * 1024;

// Wraps express.raw so oversize or malformed bodies get a JSON error instead of the default HTML page.
const parseRebaseBody: RequestHandler = (req: Request, res: Response, next: NextFunction) => {
  express.raw({ type: REBASE_CONTENT_TYPE, limit: getRebaseBodyLimit() })(req, res, (error?: unknown) => {
    if (error) {
      const status = (error as { status?: number }).status === 413 ? 413 : 400;
      res.status(status).json({ error: status === 413 ? "Payload too large" : "Invalid request body" });
      return;
    }
    if (!Buffer.isBuffer(req.body)) {
      res.status(415).json({ error: `Content-Type must be ${REBASE_CONTENT_TYPE}` });
      return;
    }
    next();
  });
};

@Controller("/fork/pages")
export class PagesController {
  [key: string]: unknown;
  private readonly hocusPocusServer: Hocuspocus;

  constructor(hocusPocusServer: Hocuspocus) {
    this.hocusPocusServer = hocusPocusServer;
    prewarmRebaseWorker();
  }

  // Read-only: only inspects the maps, never creates or loads a document. A document is in
  // `documents` from the start of loading until after its final store resolves on unload, and
  // `loadingDocuments` holds the in-flight load promise, so these two cover every window.
  @Get("/:page_id/loaded")
  @Middleware(requirePagesApiAccess)
  loaded(req: Request, res: Response) {
    const parsed = pageIdSchema.safeParse(req.params.page_id);
    if (!parsed.success) {
      return res.status(400).json({ error: "page_id must be a UUID" });
    }
    const id = parsed.data;
    const loaded = this.hocusPocusServer.documents.has(id) || this.hocusPocusServer.loadingDocuments.has(id);
    return res.status(200).json({ loaded });
  }

  // Middleware run bottom-up: access check first, so unauthenticated callers never get a body read.
  @Post("/rebase")
  @Middleware(parseRebaseBody)
  @Middleware(requirePagesApiAccess)
  async rebase(req: Request, res: Response) {
    let payload: unknown;
    try {
      payload = JSON.parse((req.body as Buffer).toString("utf8"));
    } catch {
      return res.status(400).json({ error: "Body is not valid JSON" });
    }

    const parsed = rebaseBodySchema.safeParse(payload);
    if (!parsed.success) {
      // field paths and messages only, never the submitted values
      const issues = parsed.error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message }));
      return res.status(400).json({ error: "Validation error", issues });
    }

    const limits = getRebaseLimits();
    if (
      parsed.data.description_html != null &&
      Buffer.byteLength(parsed.data.description_html, "utf8") > limits.maxHtmlBytes
    ) {
      return res.status(413).json({ error: "description_html too large", max_bytes: limits.maxHtmlBytes });
    }

    try {
      // Off the event loop, under a time budget; see rebase-runner.ts.
      const json = await runRebase(
        {
          baseBinaryBase64: parsed.data.base_binary,
          descriptionHtml: parsed.data.description_html ?? null,
          name: parsed.data.name ?? null,
        },
        { timeoutMs: limits.timeoutMs, maxConcurrency: limits.maxConcurrency }
      );
      return res.status(200).type("application/json").send(json);
    } catch (error) {
      if (error instanceof RebaseTimeoutError || error instanceof RebaseBusyError) {
        if (error instanceof RebaseBusyError) res.setHeader("Retry-After", "5");
        return res.status(503).json({ error: "Service unavailable" });
      }
      if (error instanceof InvalidBaseStateError) {
        return res.status(400).json({ error: "base_binary is not a valid document state" });
      }
      // the error message may echo content, so log the error type only
      logger.error("PAGES_CONTROLLER: rebase failed", { type: error instanceof Error ? error.name : "unknown" });
      return res.status(500).json({ error: "Internal server error" });
    }
  }
}
