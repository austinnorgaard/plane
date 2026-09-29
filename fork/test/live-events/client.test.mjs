// SPDX-License-Identifier: AGPL-3.0-only
import test from "node:test";
import assert from "node:assert/strict";
import * as C from "../../../apps/web/core/lib/live-events/client.ts";
test("backoff and close codes", () => {
  assert.equal(C.getBackoffDelay(0, 0), 1000);
  assert.equal(C.getBackoffDelay(0, 1), 1000);
  assert.equal(C.getBackoffDelay(3, 1), 8000);
  assert.equal(C.getBackoffDelay(50, 1), 30000);
  assert.equal(C.getBackoffDelay(Infinity, 0), 15000);
  for (let a = 0; a < 12; a++) {
    const d = C.getBackoffDelay(a);
    assert.ok(d >= 1000 && d <= 30000);
  }
  assert.equal(C.decideOnClose(4401), "pause");
  assert.equal(C.decideOnClose(4403), "stop");
  assert.equal(C.decideOnClose(4404), "stop");
  assert.equal(C.decideOnClose(4429), "retry-max");
  assert.equal(C.decideOnClose(4400), "stop");
  assert.equal(C.decideOnClose(4413), "stop");
  assert.equal(C.decideOnClose(4408), "retry");
  assert.equal(C.decideOnClose(1013), "retry");
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
  t.mock.timers.enable({ apis: ["setTimeout"] });
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
