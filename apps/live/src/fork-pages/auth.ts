/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { createHash, timingSafeEqual } from "crypto";
import type { NextFunction, Request, Response } from "express";
import { logger } from "@plane/logger";
import { env } from "@/env";

// Known example or placeholder values (the shipped default and the .env.example files), never accepted.
const KNOWN_WEAK_KEYS = new Set(["change-this-key-on-deployment", "secret-key"]);
export const MIN_KEY_LENGTH = 32;

const sha256 = (value: string): Buffer => createHash("sha256").update(value).digest();

/** True when the configured shared key may be used: set, not a known example, at least 32 characters. */
export const isUsableKey = (key: string | undefined): key is string =>
  typeof key === "string" && key.length >= MIN_KEY_LENGTH && !KNOWN_WEAK_KEYS.has(key);

type RefusalCause = "disabled" | "key-unusable" | "forwarded" | "key-mismatch";
const LOG_INTERVAL_MS = 60_000;
const lastLogged = new Map<RefusalCause, number>();

// The cause goes to the internal log only (rate limited, one line per cause per minute, never the key).
const logRefusal = (cause: RefusalCause) => {
  if (cause === "disabled") return;
  const now = Date.now();
  if (now - (lastLogged.get(cause) ?? 0) < LOG_INTERVAL_MS) return;
  lastLogged.set(cause, now);
  const detail =
    cause === "key-unusable"
      ? `LIVE_SERVER_SECRET_KEY is unset, an example value or shorter than ${MIN_KEY_LENGTH} characters`
      : cause === "forwarded"
        ? "the request carries X-Forwarded-For or X-Forwarded-Host (it came through a proxy)"
        : "the live-server-secret-key header does not match";
  logger.warn(`FORK_PAGES: request refused: ${detail}`);
};

/** Logs once at startup when the shared key cannot be used, naming the variable, never its value. */
export const warnIfKeyUnusable = (): void => {
  if (process.env.PAGES_API_ENABLED === "1" && !isUsableKey(env.LIVE_SERVER_SECRET_KEY)) {
    logger.warn(
      `FORK_PAGES: LIVE_SERVER_SECRET_KEY is unset, an example value or shorter than ${MIN_KEY_LENGTH} characters; the pages endpoints refuse every request`
    );
  }
};

/**
 * Shared guard for the pages endpoints. Every refusal gets the same answer, 404 {"message": "Not Found"}
 * (PLN-99, review F9), so a caller without the key cannot tell the feature flag, the key configuration
 * or the forwarded-header rule apart. Checks:
 * 1. feature flag off;
 * 2. key not usable: unset, a known example value or shorter than 32 characters (review F8);
 * 3. proxy headers present (the request did not come straight from the internal network);
 * 4. the key header does not match (digests compared in constant time).
 * The cause is logged internally at a limited rate; nothing about the request or the key is logged.
 */
export const requirePagesApiAccess = (req: Request, res: Response, next: NextFunction): void => {
  const refuse = (cause: RefusalCause) => {
    logRefusal(cause);
    res.status(404).json({ message: "Not Found" });
  };
  // The flag is read per request straight from process.env (not the validated env module) so it can be
  // switched without a restart; the secret goes through the validated env module.
  if (process.env.PAGES_API_ENABLED !== "1") return refuse("disabled");

  const configuredKey = env.LIVE_SERVER_SECRET_KEY;
  if (!isUsableKey(configuredKey)) return refuse("key-unusable");

  if (req.headers["x-forwarded-for"] !== undefined || req.headers["x-forwarded-host"] !== undefined) {
    return refuse("forwarded");
  }

  const provided = req.headers["live-server-secret-key"];
  // Compare fixed-length digests so a wrong-length key cannot throw or leak its length.
  const providedKey = typeof provided === "string" ? provided : "";
  if (!timingSafeEqual(sha256(providedKey), sha256(configuredKey))) return refuse("key-mismatch");

  next();
};
