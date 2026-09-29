/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { createHash, timingSafeEqual } from "crypto";
import type { NextFunction, Request, Response } from "express";
import { env } from "@/env";

const PLACEHOLDER_KEY = "change-this-key-on-deployment";

const sha256 = (value: string): Buffer => createHash("sha256").update(value).digest();

/**
 * Shared guard for the pages endpoints. Check order:
 * 1. feature flag off -> 404
 * 2. key not configured (empty or placeholder) -> 503
 * 3. proxy headers present (request did not come straight from the internal network) -> 403
 * 4. key header does not match -> 401
 * Nothing about the request or the key is logged.
 */
export const requirePagesApiAccess = (req: Request, res: Response, next: NextFunction): void => {
  if (process.env.PAGES_API_ENABLED !== "1") {
    res.status(404).json({ message: "Not Found" });
    return;
  }

  const configuredKey = env.LIVE_SERVER_SECRET_KEY;
  if (!configuredKey || configuredKey === PLACEHOLDER_KEY) {
    res.status(503).json({ error: "Service unavailable" });
    return;
  }

  if (req.headers["x-forwarded-for"] !== undefined || req.headers["x-forwarded-host"] !== undefined) {
    res.status(403).json({ error: "Forbidden" });
    return;
  }

  const provided = req.headers["live-server-secret-key"];
  // Compare fixed-length digests so a wrong-length key cannot throw or leak its length.
  const providedKey = typeof provided === "string" ? provided : "";
  if (!timingSafeEqual(sha256(providedKey), sha256(configuredKey))) {
    res.status(401).json({ error: "Unauthorized" });
    return;
  }

  next();
};
