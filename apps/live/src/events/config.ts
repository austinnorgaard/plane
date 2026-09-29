/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { z } from "zod";

const intFrom = (fallback: number, min = 1) =>
  z
    .string()
    .optional()
    .transform((v) => (v === undefined || v.trim() === "" ? fallback : Number(v)))
    .pipe(z.number().int().min(min));

// The live events hub reads its own settings straight from the environment so that
// env.ts stays untouched. CORS_ALLOWED_ORIGINS is deliberately not read here:
// LIVE_EVENTS_ALLOWED_ORIGINS is the explicit allowlist for the events socket.
const eventsEnvSchema = z.object({
  LIVE_EVENTS_ENABLED: z.string().optional(),
  LIVE_EVENTS_ALLOWED_ORIGINS: z.string().default(""),
  WEB_URL: z.string().default(""),
  LIVE_EVENTS_SETTLE_MS: intFrom(2000, 0),
  LIVE_EVENTS_PROJECT_RATE_PER_SEC: intFrom(50),
  LIVE_EVENTS_MAX_SOCKETS: intFrom(500),
  LIVE_EVENTS_MAX_SOCKETS_PER_USER: intFrom(10),
  LIVE_EVENTS_MAX_PROJECTS_PER_SOCKET: intFrom(100),
});

export type EventsConfig = {
  enabled: boolean;
  allowedOrigins: string[];
  webUrl: string;
  settleMs: number;
  projectRatePerSec: number;
  maxSockets: number;
  maxSocketsPerUser: number;
  maxProjectsPerSocket: number;
  maxMessageBytes: number;
  maxInboundPerSec: number;
  maxBufferedBytes: number;
  coalesceMs: number;
  maxItemsPerFrame: number;
  firstMessageMs: number;
  pingIntervalMs: number;
  maxMissedPongs: number;
  revalidateMs: number;
};

export const EVENTS_CHANNEL_PREFIX = "plane:live-events:";
export const EVENTS_CHANNEL_PATTERN = `${EVENTS_CHANNEL_PREFIX}*`;

export const parseEventsConfig = (source: Record<string, string | undefined> = process.env): EventsConfig => {
  const parsed = eventsEnvSchema.parse(source);
  return {
    enabled: parsed.LIVE_EVENTS_ENABLED === "1",
    allowedOrigins: parsed.LIVE_EVENTS_ALLOWED_ORIGINS.split(","),
    webUrl: parsed.WEB_URL,
    settleMs: parsed.LIVE_EVENTS_SETTLE_MS,
    projectRatePerSec: parsed.LIVE_EVENTS_PROJECT_RATE_PER_SEC,
    maxSockets: parsed.LIVE_EVENTS_MAX_SOCKETS,
    maxSocketsPerUser: parsed.LIVE_EVENTS_MAX_SOCKETS_PER_USER,
    maxProjectsPerSocket: parsed.LIVE_EVENTS_MAX_PROJECTS_PER_SOCKET,
    maxMessageBytes: 4 * 1024,
    maxInboundPerSec: 5,
    maxBufferedBytes: 256 * 1024,
    coalesceMs: 250,
    maxItemsPerFrame: 500,
    firstMessageMs: 10_000,
    pingIntervalMs: 25_000,
    maxMissedPongs: 2,
    revalidateMs: 5 * 60_000,
  };
};
