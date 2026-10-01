// SPDX-License-Identifier: AGPL-3.0-only
import test from "node:test";
import assert from "node:assert/strict";
import * as C from "../../../apps/web/core/lib/live-events/client.ts";
test("backoff and close codes", () => {
  assert.equal(C.getBackoffDelay(0, 0), 500);
  assert.equal(C.getBackoffDelay(0, 1), 1000);
  assert.equal(C.getBackoffDelay(3, 1), 8000);
  assert.equal(C.getBackoffDelay(50, 1), 30000);
  assert.equal(C.getBackoffDelay(Infinity, 0), 15000);
  for (let a = 0; a < 12; a++) {
    const d = C.getBackoffDelay(a);
    assert.ok(d >= 500 && d <= 30000);
  }
  assert.equal(C.decideOnClose(4401), "pause");
  assert.equal(C.decideOnClose(4403), "stop");
  assert.equal(C.decideOnClose(4404), "stop");
  assert.equal(C.decideOnClose(4429), "retry-max");
  assert.equal(C.decideOnClose(4400), "stop");
  assert.equal(C.decideOnClose(4413), "stop");
  assert.equal(C.decideOnClose(4408), "retry");
  assert.equal(C.decideOnClose(1013), "retry-max");
  assert.equal(C.decideOnClose(1006), "retry");
});
test("parseFrame follows the hub frames", () => {
  assert.equal(C.parseFrame("nope"), undefined);
  assert.equal(C.parseFrame('{"type":"issues"}'), undefined);
  assert.deepEqual(C.parseFrame('{"type":"ping"}'), { type: "ping" });
  assert.deepEqual(C.parseFrame('{"type":"resync"}'), { type: "resync" });
  assert.deepEqual(C.parseFrame('{"type":"unsubscribed","project_ids":["p"]}'), { type: "unsubscribed" });
  assert.deepEqual(C.parseFrame('{"type":"subscribed","project_ids":["p"],"denied":["q",1]}'), {
    type: "subscribed",
    project_ids: ["p"],
    denied: ["q"],
  });
  assert.deepEqual(C.parseFrame('{"type":"revoked","project_ids":["p"]}'), { type: "revoked", project_ids: ["p"] });
  assert.deepEqual(
    C.parseFrame(
      '{"type":"events","project_id":"p","items":[{"issue_id":"a","kinds":["issue"],"verbs":["updated"],"actor_ids":["u"]},{"nope":1}]}'
    ),
    {
      type: "events",
      project_id: "p",
      items: [{ issue_id: "a", kinds: ["issue"], verbs: ["updated"], actor_ids: ["u"] }],
      full_refresh: false,
    }
  );
  assert.equal(C.parseFrame('{"type":"events","project_id":"p","items":[],"full_refresh":true}').full_refresh, true);
  assert.equal(C.parseFrame('{"type":"events","items":[]}'), undefined);
});
// --- client with fake WebSocket, timers, document ---
const EV = {
  type: "events",
  project_id: "p",
  items: [{ issue_id: "a", kinds: ["issue"], verbs: ["updated"], actor_ids: [] }],
};
class FakeWS {
  static all = [];
  readyState = 0;
  sent = [];
  l = {};
  constructor(url) {
    this.url = url;
    FakeWS.all.push(this);
  }
  addEventListener(t, f, o) {
    (this.l[t] ??= []).push(f);
    o?.signal?.addEventListener("abort", () => (this.l[t] = this.l[t].filter((x) => x !== f)));
  }
  send(s) {
    this.sent.push(JSON.parse(s));
  }
  close() {
    this.closed = true;
  }
  fire(t, e = {}) {
    (this.l[t] ?? []).slice().forEach((f) => f(e));
  }
  open() {
    this.readyState = 1;
    this.fire("open");
  }
  msg(o) {
    this.fire("message", { data: JSON.stringify(o) });
  }
}
const evt = () => {
  const m = new Map();
  return { addEventListener: (t, f) => m.set(t, f), removeEventListener: (t) => m.delete(t), m };
};
function env(t) {
  FakeWS.all = [];
  const doc = Object.assign(evt(), { visibilityState: "visible" });
  const win = Object.assign(evt(), { location: { origin: "http://example.test", protocol: "http:" } });
  globalThis.WebSocket = FakeWS;
  globalThis.document = doc;
  globalThis.window = win;
  Object.defineProperty(globalThis, "navigator", { value: { onLine: true }, configurable: true });
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_000_000 });
  return { doc, win };
}
test("client: url, ref count, resync on reconnect, close codes", (t) => {
  const { win } = env(t);
  const client = new C.LiveEventsClient();
  const got = [];
  const un1 = client.subscribe("w", "p", (e) => got.push(e));
  const un2 = client.subscribe("w", "p", (e) => got.push(e));
  assert.equal(FakeWS.all.length, 1);
  assert.equal(FakeWS.all[0].url, "ws://example.test/live/events");
  FakeWS.all[0].open();
  assert.deepEqual(FakeWS.all[0].sent, [{ type: "subscribe", workspace_slug: "w", project_ids: ["p"] }]);
  assert.equal(got.length, 0, "no resync on first connect");
  FakeWS.all[0].msg(EV);
  FakeWS.all[0].msg({ ...EV, project_id: "other" });
  assert.equal(got.length, 2, "two listeners, one project");
  // network drop -> backoff -> reconnect -> resync
  FakeWS.all[0].fire("close", { code: 1006 });
  assert.equal(FakeWS.all.length, 1);
  t.mock.timers.tick(30000);
  assert.equal(FakeWS.all.length, 2);
  got.length = 0;
  FakeWS.all[1].open();
  assert.deepEqual(
    got.map((e) => e.type),
    ["resync", "resync"]
  );
  // 4429 -> at least 15 s
  FakeWS.all[1].fire("close", { code: 4429 });
  t.mock.timers.tick(14000);
  assert.equal(FakeWS.all.length, 2);
  t.mock.timers.tick(16000);
  assert.equal(FakeWS.all.length, 3);
  // 4401 pauses until focus
  FakeWS.all[2].fire("close", { code: 4401 });
  t.mock.timers.tick(120000);
  assert.equal(FakeWS.all.length, 3);
  win.m.get("focus")();
  assert.equal(FakeWS.all.length, 4);
  // 4404 stops for good
  FakeWS.all[3].fire("close", { code: 4404 });
  t.mock.timers.tick(120000);
  win.m.get("focus")();
  assert.equal(FakeWS.all.length, 4);
  un1();
  un2();
});
test("client: last unsubscribe closes the socket; unsubscribe frame", (t) => {
  env(t);
  const client = new C.LiveEventsClient();
  const un1 = client.subscribe("w", "p", () => {});
  const un2 = client.subscribe("w", "q", () => {});
  const ws = FakeWS.all[0];
  ws.open();
  un1();
  assert.deepEqual(ws.sent.at(-1), { type: "unsubscribe", project_ids: ["p"] });
  assert.equal(ws.closed, undefined);
  un2();
  assert.equal(ws.closed, true);
});
test("client: watchdog forces reconnect after 60 s of silence; ping resets it", (t) => {
  env(t);
  const client = new C.LiveEventsClient();
  client.subscribe("w", "p", () => {});
  const ws = FakeWS.all[0];
  ws.open();
  t.mock.timers.tick(50000);
  ws.msg({ type: "ping" });
  t.mock.timers.tick(50000);
  assert.equal(ws.closed, undefined);
  t.mock.timers.tick(11000);
  assert.equal(ws.closed, true);
  t.mock.timers.tick(30000);
  assert.equal(FakeWS.all.length, 2);
});
test("client: hidden buffer flush, overflow -> resync, 5 min close -> resync on visible", (t) => {
  const { doc } = env(t);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e));
  const ws = FakeWS.all[0];
  ws.open();
  doc.visibilityState = "hidden";
  doc.m.get("visibilitychange")();
  ws.msg(EV);
  assert.equal(got.length, 0);
  doc.visibilityState = "visible";
  doc.m.get("visibilitychange")();
  assert.equal(got.length, 1);
  // overflow
  got.length = 0;
  doc.visibilityState = "hidden";
  doc.m.get("visibilitychange")();
  ws.msg({ ...EV, items: Array.from({ length: 201 }, (_, i) => ({ ...EV.items[0], issue_id: "i" + i })) });
  doc.visibilityState = "visible";
  doc.m.get("visibilitychange")();
  assert.deepEqual(
    got.map((e) => e.type),
    ["resync"]
  );
  // 5 minutes hidden
  got.length = 0;
  doc.visibilityState = "hidden";
  doc.m.get("visibilitychange")();
  for (let i = 0; i < 8; i++) {
    t.mock.timers.tick(30000);
    ws.msg({ type: "ping" });
  }
  assert.equal(ws.closed, undefined);
  for (let i = 0; i < 2; i++) {
    t.mock.timers.tick(30000);
    ws.msg({ type: "ping" });
  }
  t.mock.timers.tick(1000);
  assert.equal(ws.closed, true);
  t.mock.timers.tick(10 * 60000);
  assert.equal(FakeWS.all.length, 1, "stays closed while hidden");
  doc.visibilityState = "visible";
  doc.m.get("visibilitychange")();
  assert.equal(FakeWS.all.length, 2);
  FakeWS.all[1].open();
  assert.deepEqual(
    got.map((e) => e.type),
    ["resync"]
  );
});
test("client: offline stops, online reconnects with resync", (t) => {
  const { win } = env(t);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e));
  FakeWS.all[0].open();
  navigator.onLine = false;
  win.m.get("offline")();
  assert.equal(FakeWS.all[0].closed, true);
  t.mock.timers.tick(120000);
  assert.equal(FakeWS.all.length, 1);
  navigator.onLine = true;
  win.m.get("online")();
  assert.equal(FakeWS.all.length, 2);
  FakeWS.all[1].open();
  assert.deepEqual(
    got.map((e) => e.type),
    ["resync"]
  );
});

test("client: pong reply, denied projects are not re-requested, revoked and hub resync are surfaced", (t) => {
  env(t);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e));
  client.subscribe("w", "q", (e) => got.push({ ...e, via: "q" }));
  let ws = FakeWS.all[0];
  ws.open();
  assert.deepEqual(ws.sent, [{ type: "subscribe", workspace_slug: "w", project_ids: ["p", "q"] }]);
  ws.sent.length = 0;
  ws.msg({ type: "ping" });
  assert.deepEqual(ws.sent, [{ type: "pong" }]);
  ws.msg({ type: "revoked", project_ids: ["q"] });
  assert.deepEqual(got, [{ type: "revoked", project_id: "q", via: "q" }]);
  got.length = 0;
  ws.msg({ type: "resync" });
  assert.deepEqual(got.map((e) => e.project_id).toSorted(), ["p", "q"]);
  assert.ok(got.every((e) => e.type === "resync"));
});
test("client: 4400 stops for good", (t) => {
  const { win } = env(t);
  const client = new C.LiveEventsClient();
  const original = console.error;
  console.error = () => {};
  client.subscribe("w", "p", () => {});
  FakeWS.all[0].open();
  FakeWS.all[0].fire("close", { code: 4400 });
  t.mock.timers.tick(120000);
  win.m.get("focus")();
  console.error = original;
  assert.equal(FakeWS.all.length, 1);
});

test("backoff: bounds, growth, cap and jitter range", () => {
  // min: the lowest possible delay is the floor, also for the first retry
  assert.equal(C.BACKOFF_FLOOR_MS, 500);
  for (let a = 0; a < 40; a++) assert.ok(C.getBackoffDelay(a, 0) >= C.BACKOFF_FLOOR_MS);
  // growth: the upper end of the jitter range doubles per attempt
  assert.deepEqual(
    [0, 1, 2, 3, 4].map((a) => C.getBackoffDelay(a, 1)),
    [1000, 2000, 4000, 8000, 16000]
  );
  // jitter range: 50%-100% of the step, monotonic in the random input, never outside the range
  for (const a of [0, 1, 2, 3, 4]) {
    const step = 1000 * 2 ** a;
    assert.equal(C.getBackoffDelay(a, 0), Math.max(500, step / 2));
    assert.equal(C.getBackoffDelay(a, 1), step);
    assert.ok(C.getBackoffDelay(a, 0.5) > C.getBackoffDelay(a, 0));
    assert.ok(C.getBackoffDelay(a, 0.5) < C.getBackoffDelay(a, 1));
    for (const r of [0, 0.1, 0.25, 0.5, 0.75, 0.99, 1]) {
      const d = C.getBackoffDelay(a, r);
      assert.ok(d >= Math.max(500, step / 2) && d <= step, `attempt ${a} random ${r}: ${d}`);
    }
  }
  // cap: never above 30 s, however many attempts, and the cap is reached
  assert.equal(C.getBackoffDelay(5, 1), 30000);
  for (const a of [5, 6, 10, 50, 1000, Infinity]) {
    assert.equal(C.getBackoffDelay(a, 1), 30000);
    assert.equal(C.getBackoffDelay(a, 0), 15000);
    assert.ok(C.getBackoffDelay(a) <= 30000);
  }
  assert.equal(C.getBackoffDelay(-3, 1), 1000);
});

test("client: reconnect delays follow the backoff and are capped, reset after a successful open", (t) => {
  env(t);
  t.mock.method(Math, "random", () => 1); // top of the jitter range
  const client = new C.LiveEventsClient();
  client.subscribe("w", "p", () => {});
  const expected = [1000, 2000, 4000, 8000, 16000, 30000, 30000];
  for (const [i, delay] of expected.entries()) {
    FakeWS.all.at(-1).fire("close", { code: 1006 });
    const before = FakeWS.all.length;
    t.mock.timers.tick(delay - 1);
    assert.equal(FakeWS.all.length, before, `attempt ${i}: not before ${delay} ms`);
    t.mock.timers.tick(1);
    assert.equal(FakeWS.all.length, before + 1, `attempt ${i}: reconnects at ${delay} ms`);
  }
  FakeWS.all.at(-1).open();
  FakeWS.all.at(-1).fire("message", { data: JSON.stringify({ type: "ping" }) }); // proved stable
  FakeWS.all.at(-1).fire("close", { code: 1006 });
  const before = FakeWS.all.length;
  t.mock.timers.tick(1000);
  assert.equal(FakeWS.all.length, before + 1, "backoff restarts from the minimum after a stable connection");
});

test("client: no refetch for a short blip, exactly one for a long gap", (t) => {
  env(t);
  t.mock.method(Math, "random", () => 0); // shortest delays
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e.type));
  FakeWS.all[0].open();
  assert.deepEqual(got, []);

  // short blip: back within the settle window
  FakeWS.all[0].fire("close", { code: 1006 });
  t.mock.timers.tick(500);
  assert.equal(FakeWS.all.length, 2);
  FakeWS.all[1].open();
  assert.deepEqual(got, [], "no resync for a blip");

  // exactly at the window: still a blip
  FakeWS.all[1].fire("close", { code: 1006 });
  t.mock.timers.tick(C.SETTLE_WINDOW_MS);
  FakeWS.all[2].open();
  assert.deepEqual(got, [], "a gap of exactly the settle window is a blip");

  // long gap spanning several failed attempts: one resync when it finally opens
  FakeWS.all[2].fire("close", { code: 1006 });
  for (let i = 0; i < 4; i++) {
    t.mock.timers.tick(30000);
    FakeWS.all.at(-1).fire("close", { code: 1006 }); // the attempt fails
  }
  t.mock.timers.tick(30000);
  FakeWS.all.at(-1).open();
  assert.deepEqual(got, ["resync"], "exactly one resync after a long gap");

  // and it is consumed: a second short blip right after does not refetch again
  FakeWS.all.at(-1).fire("close", { code: 1006 });
  t.mock.timers.tick(500);
  FakeWS.all.at(-1).open();
  assert.deepEqual(got, ["resync"]);
});

test("client: one resync per project after a long gap, not one per reconnect attempt", (t) => {
  env(t);
  t.mock.method(Math, "random", () => 0);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e.project_id));
  client.subscribe("w", "q", (e) => got.push(e.project_id));
  FakeWS.all[0].open();
  FakeWS.all[0].fire("close", { code: 1013 });
  t.mock.timers.tick(30_000);
  FakeWS.all[1].open();
  assert.deepEqual(got.toSorted(), ["p", "q"]);
});

test("client: silent death (watchdog) and an offline period always resync, whatever the clock says", (t) => {
  const { win } = env(t);
  t.mock.method(Math, "random", () => 0);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e.type));
  FakeWS.all[0].open();
  t.mock.timers.tick(C.WATCHDOG_MS); // watchdog closes the socket
  t.mock.timers.tick(1000);
  assert.equal(FakeWS.all.length, 2);
  FakeWS.all[1].open();
  assert.deepEqual(got, ["resync"]);
  got.length = 0;
  navigator.onLine = false;
  win.m.get("offline")();
  navigator.onLine = true;
  win.m.get("online")(); // back within one second
  FakeWS.all.at(-1).open();
  assert.deepEqual(got, ["resync"]);
});

for (const code of [4403, 4404, 4400, 4413]) {
  test(`client: close code ${code} does not reconnect, however long the wait`, (t) => {
    env(t);
    const client = new C.LiveEventsClient();
    const original = console.error;
    console.error = () => {};
    client.subscribe("w", "p", () => {});
    FakeWS.all[0].open();
    FakeWS.all[0].fire("close", { code });
    t.mock.timers.tick(10 * 60000);
    console.error = original;
    assert.equal(FakeWS.all.length, 1);
  });
}

test("client: an online event with a healthy socket leaves no stale resync behind", (t) => {
  const { win } = env(t);
  t.mock.method(Math, "random", () => 0);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e.type));
  FakeWS.all[0].open();
  win.m.get("online")();
  FakeWS.all[0].fire("close", { code: 1006 });
  t.mock.timers.tick(500);
  FakeWS.all[1].open();
  assert.deepEqual(got, [], "a short blip after a spurious online event does not refetch");
});

test("client: a hub that opens and closes with 1013 does not reset the backoff", (t) => {
  env(t);
  t.mock.method(Math, "random", () => 1);
  const client = new C.LiveEventsClient();
  client.subscribe("w", "p", () => {});
  const delays = [];
  for (let i = 0; i < 4; i++) {
    const ws = FakeWS.all.at(-1);
    ws.open();
    ws.fire("close", { code: 1013 });
    const before = FakeWS.all.length;
    let waited = 0;
    while (FakeWS.all.length === before && waited < 100_000) {
      t.mock.timers.tick(500);
      waited += 500;
    }
    delays.push(waited);
  }
  // 1013 retries at the maximum backoff and never falls back to the first step
  assert.deepEqual(delays, [30000, 30000, 30000, 30000]);
});

test("client: open then plain drops grow the delays until the connection proves stable", (t) => {
  env(t);
  t.mock.method(Math, "random", () => 1);
  const client = new C.LiveEventsClient();
  client.subscribe("w", "p", () => {});
  const delays = [];
  for (let i = 0; i < 4; i++) {
    const ws = FakeWS.all.at(-1);
    ws.open();
    t.mock.timers.tick(100); // open for less than the settle window, no frame
    ws.fire("close", { code: 1011 });
    const before = FakeWS.all.length;
    let waited = 0;
    while (FakeWS.all.length === before && waited < 100_000) {
      t.mock.timers.tick(500);
      waited += 500;
    }
    delays.push(waited);
  }
  assert.deepEqual(delays, [1000, 2000, 4000, 8000]);
});

test("client: the counter resets after a first frame, and after staying open for the settle window", (t) => {
  env(t);
  t.mock.method(Math, "random", () => 1);
  const client = new C.LiveEventsClient();
  client.subscribe("w", "p", () => {});
  const dropAndMeasure = () => {
    FakeWS.all.at(-1).fire("close", { code: 1006 });
    const before = FakeWS.all.length;
    let waited = 0;
    while (FakeWS.all.length === before && waited < 100_000) {
      t.mock.timers.tick(250);
      waited += 250;
    }
    return waited;
  };
  // grow the backoff: three failed attempts
  assert.equal(dropAndMeasure(), 1000);
  assert.equal(dropAndMeasure(), 2000);
  assert.equal(dropAndMeasure(), 4000);
  // the server opens, sends a frame and stays up: reset
  FakeWS.all.at(-1).open();
  FakeWS.all.at(-1).fire("message", { data: JSON.stringify({ type: "subscribed", project_ids: ["p"], denied: [] }) });
  assert.equal(dropAndMeasure(), 1000, "reset after the first server frame");
  assert.equal(dropAndMeasure(), 2000);
  // opens and stays up without a frame for the settle window: reset as well
  FakeWS.all.at(-1).open();
  t.mock.timers.tick(C.SETTLE_WINDOW_MS - 1);
  FakeWS.all.at(-1).fire("close", { code: 1006 });
  const grown = (() => {
    const before = FakeWS.all.length;
    let waited = 0;
    while (FakeWS.all.length === before) {
      t.mock.timers.tick(250);
      waited += 250;
    }
    return waited;
  })();
  assert.equal(grown, 4000, "just under the settle window does not reset");
  FakeWS.all.at(-1).open();
  t.mock.timers.tick(C.SETTLE_WINDOW_MS);
  assert.equal(dropAndMeasure(), 1000, "reset after staying open for the settle window");
});

test("client: a hub resync frame right after the reopen resync is not a second refetch", (t) => {
  env(t);
  t.mock.method(Math, "random", () => 0);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e.type));
  FakeWS.all[0].open();
  FakeWS.all[0].fire("close", { code: 1006 });
  t.mock.timers.tick(30_000);
  FakeWS.all[1].open();
  assert.deepEqual(got, ["resync"]);
  FakeWS.all[1].fire("message", { data: JSON.stringify({ type: "resync" }) });
  assert.deepEqual(got, ["resync"], "duplicate inside the settle window is skipped");
  t.mock.timers.tick(C.SETTLE_WINDOW_MS + 1);
  FakeWS.all[1].fire("message", { data: JSON.stringify({ type: "resync" }) });
  assert.deepEqual(got, ["resync", "resync"], "a later hub resync still refetches");
});

test("client: hidden tab becomes visible after socket closed: reconnect immediately", (t) => {
  const { doc } = env(t);
  t.mock.method(Math, "random", () => 0);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e.type));
  const ws1 = FakeWS.all[0];
  ws1.open();
  got.length = 0;
  // hide the tab for long enough to close the socket
  doc.visibilityState = "hidden";
  doc.m.get("visibilitychange")();
  t.mock.timers.tick(C.HIDDEN_CLOSE_MS);
  assert.equal(ws1.closed, true, "socket closed after hidden timeout");
  assert.equal(FakeWS.all.length, 1, "no reconnect yet, waiting for backoff");
  // become visible: should cancel backoff and reconnect immediately
  doc.visibilityState = "visible";
  doc.m.get("visibilitychange")();
  assert.equal(FakeWS.all.length, 2, "reconnected immediately on visibility change");
  FakeWS.all[1].open();
  // the gap was long enough that resync fires
  assert.deepEqual(got, ["resync"], "exactly one resync after the gap");
});

test("client: open socket: visibility change flushes hidden buffer but does not create new socket", (t) => {
  const { doc } = env(t);
  const client = new C.LiveEventsClient();
  const got = [];
  client.subscribe("w", "p", (e) => got.push(e));
  const ws1 = FakeWS.all[0];
  ws1.open();
  // hide the tab
  doc.visibilityState = "hidden";
  doc.m.get("visibilitychange")();
  // send event while hidden (should be buffered)
  ws1.msg(EV);
  assert.equal(got.length, 0, "event buffered while hidden");
  // become visible
  doc.visibilityState = "visible";
  doc.m.get("visibilitychange")();
  // buffer should be flushed but no new socket created
  assert.equal(FakeWS.all.length, 1, "no new socket when visible with open socket");
  assert.equal(got.length, 1, "buffered event flushed");
  assert.equal(got[0].type, "events", "flushed correct event type");
});

test("client: when paused, visibility change does not attempt onActivity (no reconnect)", (t) => {
  const { doc, win } = env(t);
  const client = new C.LiveEventsClient();
  client.subscribe("w", "p", () => {});
  const ws1 = FakeWS.all[0];
  ws1.open();
  // close with pause code
  ws1.fire("close", { code: 4401 });
  const countAfterPause = FakeWS.all.length;
  assert.equal(countAfterPause, 1, "no reconnect scheduled on pause");
  // try visibility change while paused
  doc.visibilityState = "hidden";
  doc.m.get("visibilitychange")();
  doc.visibilityState = "visible";
  doc.m.get("visibilitychange")();
  // visibility change should not attempt to reconnect when paused
  assert.equal(FakeWS.all.length, countAfterPause, "visibility does not reconnect when paused");
  // verify focus can lift pause
  win.m.get("focus")();
  assert.ok(FakeWS.all.length > countAfterPause, "focus lifts pause and causes reconnect");
});

test("client: when stopped, visibility change does not attempt onActivity (no reconnect)", (t) => {
  const { doc, win } = env(t);
  for (const code of [4400, 4403, 4404, 4413]) {
    FakeWS.all = [];
    const client = new C.LiveEventsClient();
    const original = console.error;
    console.error = () => {};
    client.subscribe("w", "p", () => {});
    const ws1 = FakeWS.all[0];
    ws1.open();
    // close with stop code
    ws1.fire("close", { code });
    const countAfterStop = FakeWS.all.length;
    assert.equal(countAfterStop, 1, `no reconnect scheduled on stop code ${code}`);
    // try visibility change while stopped
    doc.visibilityState = "hidden";
    doc.m.get("visibilitychange")();
    doc.visibilityState = "visible";
    doc.m.get("visibilitychange")();
    // visibility change should not attempt to reconnect when stopped
    assert.equal(FakeWS.all.length, countAfterStop, `visibility does not reconnect when stopped (${code})`);
    // verify focus also cannot lift the stop state
    win.m.get("focus")();
    assert.equal(FakeWS.all.length, countAfterStop, `focus cannot lift stopped state (${code})`);
    console.error = original;
  }
});

test("client: visibility change does nothing after unsubscribe (dispose)", (t) => {
  const { doc } = env(t);
  t.mock.method(Math, "random", () => 0);
  const client = new C.LiveEventsClient();
  const unsub = client.subscribe("w", "p", () => {});
  const ws1 = FakeWS.all[0];
  ws1.open();
  // close the socket: backoff timer is scheduled
  ws1.fire("close", { code: 1006 });
  // unsubscribe (dispose) - this detaches global listeners
  unsub();
  // the listener should be removed on dispose
  assert.strictEqual(doc.m.get("visibilitychange"), undefined, "visibility listener removed on dispose");
  // verify no socket is created after unsubscribe
  assert.equal(FakeWS.all.length, 1, "no reconnect after unsubscribe");
});
