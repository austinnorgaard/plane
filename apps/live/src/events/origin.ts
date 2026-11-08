/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// Close code used for a rejected Origin.
export const CLOSE_ORIGIN = 4403;

const DEFAULT_PORTS: Record<string, string> = { "http:": "80", "https:": "443" };

/** Normalise one origin-like string to `scheme://host[:port]` (lowercase, default port stripped). */
export const normalizeOrigin = (value: string): string | null => {
  try {
    const url = new URL(value.trim());
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    if (url.port === DEFAULT_PORTS[url.protocol]) url.port = "";
    return `${url.protocol}//${url.host}`.toLowerCase();
  } catch {
    return null;
  }
};

/** Split each comma separated entry, trim, drop empties and normalise. */
export const buildAllowlist = (entries: string[]): Set<string> => {
  const out = new Set<string>();
  for (const entry of entries) {
    for (const part of entry.split(",")) {
      const trimmed = part.trim();
      if (!trimmed) continue;
      const normalized = normalizeOrigin(trimmed);
      if (normalized) out.add(normalized);
    }
  }
  return out;
};

const firstHeaderValue = (value: string | string[] | undefined): string => {
  const raw = Array.isArray(value) ? value[0] : value;
  return (raw ?? "").split(",")[0].trim().toLowerCase();
};

const stripDefaultPort = (host: string): string => host.replace(/:(80|443)$/, "");

export type OriginInput = {
  origin: string | string[] | undefined;
  host: string | string[] | undefined;
  forwardedHost: string | string[] | undefined;
};

/**
 * Accept when the Origin is in the allowlist, or when its host[:port] equals the first
 * X-Forwarded-Host value (Host when that header is absent). The scheme is not compared
 * for the host match because a tunnel may hand the proxy plain http while the browser's
 * Origin is https. A missing Origin or the literal "null" is always rejected.
 */
export const isOriginAllowed = (input: OriginInput, allowlist: Set<string>): boolean => {
  const rawOrigin = Array.isArray(input.origin) ? input.origin[0] : input.origin;
  // the literal "null" is not a URL, so normalizeOrigin rejects it below
  if (!rawOrigin) return false;
  const normalized = normalizeOrigin(rawOrigin);
  if (!normalized) return false;
  if (allowlist.has(normalized)) return true;

  const requestHost = firstHeaderValue(input.forwardedHost) || firstHeaderValue(input.host);
  if (!requestHost) return false;
  const originHost = normalized.replace(/^https?:\/\//, "");
  return stripDefaultPort(originHost) === stripDefaultPort(requestHost);
};
