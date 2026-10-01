/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

import { BlockList, isIP } from "net";

const normalize = (value: string | undefined): string | null => {
  if (!value) return null;
  let v = value.trim();
  if (v.toLowerCase().startsWith("::ffff:") && isIP(v.slice(7)) === 4) v = v.slice(7);
  return isIP(v) ? v.toLowerCase() : null;
};

const familyOf = (ip: string) => (isIP(ip) === 6 ? "ipv6" : "ipv4");

/** Entries are single addresses or CIDR ranges. Returns the list and how many entries were unusable. */
export const buildTrustedProxies = (entries: string[]): { list: BlockList; invalid: number } => {
  const list = new BlockList();
  let invalid = 0;
  for (const entry of entries) {
    const [addr, prefix, ...rest] = entry.split("/");
    const ip = normalize(addr);
    const bits = prefix === undefined ? null : Number(prefix);
    const max = ip && isIP(ip) === 6 ? 128 : 32;
    if (!ip || rest.length > 0 || (bits !== null && (!Number.isInteger(bits) || bits < 0 || bits > max))) {
      invalid++;
      continue;
    }
    if (bits === null) list.addAddress(ip, familyOf(ip));
    else list.addSubnet(ip, bits, familyOf(ip));
  }
  return { list, invalid };
};

/**
 * The address a socket is attributed to. X-Forwarded-For is read only when the direct peer is a
 * trusted proxy; the chain is then walked from the right and the first address that is not itself
 * a trusted proxy wins. Anything else uses the direct peer. Returns null when no address is known.
 */
export const resolveClientAddress = (
  peer: string | undefined,
  forwardedFor: string | string[] | undefined,
  trusted: BlockList
): string | null => {
  const direct = normalize(peer);
  if (!direct) return null;
  const isTrusted = (ip: string) => trusted.check(ip, familyOf(ip));
  if (!isTrusted(direct)) return direct;
  const chain = (Array.isArray(forwardedFor) ? forwardedFor.join(",") : (forwardedFor ?? ""))
    .split(",")
    .map((p) => normalize(p));
  for (let i = chain.length - 1; i >= 0; i--) {
    const hop = chain[i];
    if (hop === null) return direct; // malformed entry: do not guess
    if (!isTrusted(hop)) return hop;
  }
  return direct;
};
