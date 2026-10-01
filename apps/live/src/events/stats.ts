/**
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { createHash, timingSafeEqual } from "crypto";
import type { NextFunction, Request, Response } from "express";
import { env } from "@/env";
import type { HubStats } from "./hub";

const PLACEHOLDER_KEY = "change-this-key-on-deployment";

/** The running hub, registered by the events controller so the health controller can read its counters. */
let statsSource: (() => HubStats) | null = null;
export const registerStatsSource = (source: (() => HubStats) | null): void => {
  statsSource = source;
};

export type LiveStats = {
  startedAt: string;
  uptimeSeconds: number;
  eventsEnabled: boolean;
  events: HubStats | null;
};

export const collectStats = (now: number = Date.now()): LiveStats => {
  const uptimeSeconds = Math.floor(process.uptime());
  return {
    startedAt: new Date(now - uptimeSeconds * 1000).toISOString(),
    uptimeSeconds,
    eventsEnabled: statsSource !== null,
    events: statsSource ? statsSource() : null,
  };
};

const sha256 = (value: string): Buffer => createHash("sha256").update(value).digest();

/**
 * Guard for the counters endpoint: the live shared secret header, compared on fixed-length digests
 * with timingSafeEqual. Unconfigured or placeholder secret -> 503, missing or wrong -> 401.
 * Nothing about the request or the secret is logged.
 */
export const requireStatsAccess = (req: Request, res: Response, next: NextFunction): void => {
  const configured = env.LIVE_SERVER_SECRET_KEY;
  if (!configured || configured === PLACEHOLDER_KEY) {
    res.status(503).json({ error: "Service unavailable" });
    return;
  }
  const provided = req.headers["live-server-secret-key"];
  const providedKey = typeof provided === "string" ? provided : "";
  if (!timingSafeEqual(sha256(providedKey), sha256(configured))) {
    res.status(401).json({ error: "Unauthorized" });
    return;
  }
  next();
};
