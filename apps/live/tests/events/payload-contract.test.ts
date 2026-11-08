/**
 * Copyright (c) 2023-present Plane Software, Inc. and contributors
 * SPDX-License-Identifier: AGPL-3.0-only
 * See the LICENSE file for details.
 */

// The hub against the shared fixtures in fork/contracts/live-events. The api publisher tests
// (apps/api/plane/tests/unit/live_events/test_payload_contract.py) read the same file, so a
// payload change on one side fails the other side's suite.

import { readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EVENT_KINDS, EVENT_VERBS, redisMessageSchema } from "@/events/hub";
import { ALICE, connect, defaultState, makeHub, subscribe } from "./helpers";

vi.hoisted(() => {
  // the live env module validates these at import time
  process.env.API_BASE_URL = "http://api.invalid";
  process.env.LIVE_SERVER_SECRET_KEY = "test-value";
});

type ValidCase = { name: string; producer: boolean; payload: Record<string, any> };
type InvalidCase = { name: string; payload?: unknown; raw?: string };
type Contract = {
  channel_prefix: string;
  kinds: string[];
  verbs: string[];
  valid: ValidCase[];
  invalid: InvalidCase[];
};

const CONTRACT_PATH = path.resolve(__dirname, "../../../../fork/contracts/live-events/events.json");
const contract: Contract = JSON.parse(readFileSync(CONTRACT_PATH, "utf8"));
const wire = (c: { payload?: unknown; raw?: string }) => (c.raw !== undefined ? c.raw : JSON.stringify(c.payload));

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe("live event payload contract: vocabulary", () => {
  it("has the same kinds and verbs as the fixtures", () => {
    expect([...EVENT_KINDS].toSorted()).toEqual([...contract.kinds].toSorted());
    expect([...EVENT_VERBS].toSorted()).toEqual([...contract.verbs].toSorted());
  });

  it("has fixtures", () => {
    expect(contract.valid.length).toBeGreaterThan(0);
    expect(contract.invalid.length).toBeGreaterThan(0);
  });
});

describe("live event payload contract: schema", () => {
  it.each(contract.valid.map((c) => [c.name, c] as const))("accepts valid fixture %s", (_name, c) => {
    const result = redisMessageSchema.safeParse(JSON.parse(wire(c)));
    expect(result.success).toBe(true);
  });

  it.each(contract.invalid.map((c) => [c.name, c] as const))("rejects invalid fixture %s", (_name, c) => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(wire(c));
    } catch {
      return; // not JSON: the hub drops it before validation
    }
    expect(redisMessageSchema.safeParse(parsed).success).toBe(false);
  });

  it("keeps the fields the hub reads from a valid fixture", () => {
    for (const c of contract.valid.filter((v) => v.producer)) {
      const result = redisMessageSchema.safeParse(c.payload);
      expect(result.success).toBe(true);
      if (!result.success) continue;
      const data = result.data as Record<string, unknown>;
      for (const field of ["v", "project_id", "issue_ids", "kind", "verb"])
        expect(data[field]).toEqual(c.payload[field]);
    }
  });
});

describe("live event payload contract: through the hub", () => {
  const project = contract.valid[0].payload.project_id as string;
  const state = () => {
    const s = defaultState();
    s.roles.acme[ALICE] = { [project]: 20 };
    return s;
  };

  it.each(contract.valid.map((c) => [c.name, c] as const))("delivers valid fixture %s", async (_name, c) => {
    const { hub, sub } = makeHub({}, state());
    await hub.start();
    const ws = await connect(hub);
    await subscribe(ws, "acme", [project]);
    sub.publish(project, wire(c));
    vi.advanceTimersByTime(300);
    expect(hub.invalidDropped).toBe(0);
    expect(ws.of("events")).toHaveLength(1);
  });

  it("drops every invalid fixture and counts it", async () => {
    const { hub, sub } = makeHub({}, state());
    await hub.start();
    const ws = await connect(hub);
    await subscribe(ws, "acme", [project]);
    for (const c of contract.invalid) sub.publish(project, wire(c));
    vi.advanceTimersByTime(300);
    expect(ws.of("events")).toEqual([]);
    expect(hub.invalidDropped).toBe(contract.invalid.length);
  });
});
