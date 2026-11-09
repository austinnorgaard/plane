/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import type { Hocuspocus } from "@hocuspocus/server";
import express from "express";
import type { NextFunction, Request, RequestHandler, Response } from "express";
import { z } from "zod";
import { Controller, Delete, Get, Middleware, Post } from "@plane/decorators";
import { logger } from "@plane/logger";
import { requirePagesApiAccess, warnIfKeyUnusable } from "./auth";
import { InvalidBaseStateError } from "./rebase";
import { prewarmRebaseWorker, RebaseBusyError, RebaseTimeoutError, runRebase } from "./rebase-runner";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";

export const REBASE_CONTENT_TYPE = "application/vnd.plane-fork.rebase+json";
const MAX_BASE_BINARY_BYTES = 10 * 1024 * 1024;
// base64 length of the largest allowed binary (4 chars per 3 bytes, padded)
const MAX_BASE_BINARY_CHARS = Math.ceil(MAX_BASE_BINARY_BYTES / 3) * 4;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

const pageIdSchema = z.string().uuid();
const lockTokenSchema = z.string().uuid();
export const WRITE_LOCK_TOKEN_HEADER = "x-fork-write-lock-token";

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

// Error body of a raw request body over the cap. Distinct from the html cap's
// {"error": "description_html too large"} (PLN-99): the api tells the two apart.
export const BODY_TOO_LARGE_ERROR = "request body too large";

// Wraps express.raw so oversize or malformed bodies get a JSON error instead of the default HTML page.
const parseRebaseBody: RequestHandler = (req: Request, res: Response, next: NextFunction) => {
  const limit = getRebaseBodyLimit();
  express.raw({ type: REBASE_CONTENT_TYPE, limit })(req, res, (error?: unknown) => {
    if (error) {
      if ((error as { status?: number }).status === 413) {
        res.status(413).json({ error: BODY_TOO_LARGE_ERROR, max_bytes: limit });
        return;
      }
      res.status(400).json({ error: "Invalid request body" });
      return;
    }
    if (!Buffer.isBuffer(req.body)) {
      res.status(415).json({ error: `Content-Type must be ${REBASE_CONTENT_TYPE}` });
      return;
    }
    next();
  });
};

/**
 * fork (PLN-99): a --max-old-space-size in NODE_OPTIONS overrides the per-worker heap limit of the rebase
 * workers (PAGES_REBASE_WORKER_MAX_MB), so one large rebase could grow far beyond it. Warn once.
 */
const warnIfNodeOldSpaceSet = () => {
  if (/--max[-_]old[-_]space[-_]size/.test(process.env.NODE_OPTIONS ?? "")) {
    logger.warn(
      "PAGES_CONTROLLER: NODE_OPTIONS sets --max-old-space-size, which overrides the rebase worker heap limit (PAGES_REBASE_WORKER_MAX_MB); remove it for live"
    );
  }
};

@Controller("/fork/pages")
export class PagesController {
  [key: string]: unknown;
  private readonly hocusPocusServer: Hocuspocus;

  constructor(hocusPocusServer: Hocuspocus) {
    this.hocusPocusServer = hocusPocusServer;
    prewarmRebaseWorker();
    // fork (PLN-99): configuration problems are named once at startup (never a value)
    warnIfKeyUnusable();
    warnIfNodeOldSpaceSet();
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

  // fork (PLN-98): the document write lock (see write-lock.ts). Granted only while the page is not
  // loaded; the presence check and the lock are one synchronous step, so no load can start in between.
  // Answers 200 {acquired: true, token, ttl_ms} or 200 {acquired: false, reason: "loaded" | "busy"}.
  @Post("/:page_id/write-lock")
  @Middleware(requirePagesApiAccess)
  lock(req: Request, res: Response) {
    const parsed = pageIdSchema.safeParse(req.params.page_id);
    if (!parsed.success) {
      return res.status(400).json({ error: "page_id must be a UUID" });
    }
    const id = parsed.data;
    if (this.hocusPocusServer.documents.has(id) || this.hocusPocusServer.loadingDocuments.has(id)) {
      return res.status(200).json({ acquired: false, reason: "loaded" });
    }
    const result = acquireWriteLock(id);
    if (!result.acquired) return res.status(200).json({ acquired: false, reason: result.reason });
    return res.status(200).json({ acquired: true, token: result.token, ttl_ms: result.ttlMs });
  }

  // fork (PLN-98): release after the api commit. 204 when released, 404 when the lock was not held
  // (expired, or a wrong token).
  @Delete("/:page_id/write-lock")
  @Middleware(requirePagesApiAccess)
  unlock(req: Request, res: Response) {
    const id = pageIdSchema.safeParse(req.params.page_id);
    const token = lockTokenSchema.safeParse(req.headers[WRITE_LOCK_TOKEN_HEADER]);
    if (!id.success || !token.success) {
      return res.status(400).json({ error: "page_id and the lock token must be UUIDs" });
    }
    if (!releaseWriteLock(id.data, token.data)) return res.status(404).json({ error: "lock not held" });
    return res.status(204).end();
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
