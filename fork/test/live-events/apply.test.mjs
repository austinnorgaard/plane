// SPDX-License-Identifier: AGPL-3.0-only
import test from "node:test";
import assert from "node:assert/strict";
import * as A from "../../../apps/web/core/lib/live-events/apply.ts";
import { LiveWorkItemsApplier } from "../../../apps/web/core/lib/live-events/apply.ts";
test("decide: project", () => {
  const issue = { project_id: "p" };
  assert.equal(A.decideStoreAction({ scope: { kind: "project" }, projectId: "p", issue, inList: false }), "add");
  assert.equal(A.decideStoreAction({ scope: { kind: "project" }, projectId: "p", issue, inList: true }), "update");
  assert.equal(
    A.decideStoreAction({ scope: { kind: "project" }, projectId: "p", issue: { project_id: "x" }, inList: true }),
    "remove"
  );
  assert.equal(
    A.decideStoreAction({ scope: { kind: "project" }, projectId: "p", issue: { project_id: "x" }, inList: false }),
    "none"
  );
});
test("decide: cycle and module", () => {
  const c = { kind: "cycle", cycleId: "c1" },
    m = { kind: "module", moduleId: "m1" };
  assert.equal(
    A.decideStoreAction({ scope: c, projectId: "p", issue: { project_id: "p", cycle_id: "c1" }, inList: false }),
    "add"
  );
  assert.equal(
    A.decideStoreAction({ scope: c, projectId: "p", issue: { project_id: "p", cycle_id: "c2" }, inList: true }),
    "remove"
  );
  assert.equal(
    A.decideStoreAction({ scope: c, projectId: "p", issue: { project_id: "p", cycle_id: null }, inList: false }),
    "none"
  );
  assert.equal(
    A.decideStoreAction({
      scope: m,
      projectId: "p",
      issue: { project_id: "p", module_ids: ["m1", "m2"] },
      inList: true,
    }),
    "update"
  );
  assert.equal(
    A.decideStoreAction({ scope: m, projectId: "p", issue: { project_id: "p", module_ids: [] }, inList: true }),
    "remove"
  );
  assert.equal(
    A.decideStoreAction({ scope: m, projectId: "p", issue: { project_id: "p", module_ids: null }, inList: false }),
    "none"
  );
});
test("helpers", () => {
  assert.equal(A.listContainsIssue({ a: { b: ["1", "2"] }, c: ["3"] }, "2"), true);
  assert.equal(A.listContainsIssue({ a: ["1"] }, "9"), false);
  assert.equal(A.listContainsIssue(undefined, "9"), false);
  assert.equal(A.isFilterExpressionActive({}), false);
  assert.equal(A.isFilterExpressionActive(undefined), false);
  assert.equal(A.isFilterExpressionActive({ and: [1] }), true);
  const ids = Array.from({ length: 120 }, (_, i) => String(i));
  assert.deepEqual(
    A.chunkIds(ids).map((c) => c.length),
    [50, 50, 20]
  );
  assert.equal(A.shouldResetComments(["comment:created"]), false);
  assert.equal(A.shouldResetComments(["comment:created", "comment:deleted"]), true);
  assert.equal(A.shouldResetComments(["comment_reaction:created"]), true);
  assert.equal(A.shouldResetComments(["issue:updated"]), false);
  assert.equal(A.hasCommentChange(["issue:updated", "comment:created"]), true);
  assert.equal(A.hasCommentChange(["issue:updated"]), false);
  assert.deepEqual(A.itemChangeKeys({ kinds: ["issue", "comment"], verbs: ["updated"] }), [
    "issue:updated",
    "comment:updated",
  ]);
  assert.deepEqual(A.itemChangeKeys({ kinds: [], verbs: [] }), ["issue:updated"]);
  assert.equal(A.isOwnItem({ actor_ids: ["me"] }, "me"), true);
  assert.equal(A.isOwnItem({ actor_ids: ["me", "x"] }, "me"), false);
  assert.equal(A.isOwnItem({ actor_ids: [] }, "me"), false);
});
function setup(t, { route = {}, peek, present = {}, listed = [], filtered = false } = {}) {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const calls = [];
  const map = { ...present };
  const issueMap = {
    getIssueById: (id) => map[id],
    addIssue: (l) =>
      l.forEach((i) => {
        calls.push(["map.add", i.id]);
        map[i.id] = { ...map[i.id], ...i };
      }),
    removeIssue: (id) => {
      calls.push(["map.remove", id]);
      delete map[id];
    },
  };
  const mkStore = () => ({
    groupedIssueIds: { ALL: [...listed] },
    addIssueToList: (id) => calls.push(["addToList", id]),
    updateIssueList: (a, b, act) => calls.push(["updateList", a?.id, b?.id, act]),
    removeIssueFromList: (id) => {
      calls.push(["removeFromList", id, id in map]);
    },
    fetchIssuesWithExistingPagination: async () => calls.push(["coarse"]),
  });
  const project = mkStore(),
    cycle = mkStore();
  const detail = {
    peekIssue: peek,
    comment: { comments: { i1: ["c"] } },
    setPeekIssue: (v) => calls.push(["setPeek", v]),
    fetchIssue: async (...a) => calls.push(["fetchIssue", a[2]]),
    fetchComments: async (...a) => calls.push(["fetchComments", a[2]]),
    fetchActivities: async (...a) => calls.push(["fetchActivities", a[2]]),
  };
  const retrieved = [];
  globalThis.__retrieveIssues = async (ws, p, ids) => {
    retrieved.push(ids);
    return globalThis.__resp(ids);
  };
  const applier = new LiveWorkItemsApplier({
    workspaceSlug: "w",
    projectId: "p",
    getRoute: () => route,
    getCurrentUserId: () => "me",
    issueMap,
    projectIssues: project,
    cycleIssues: cycle,
    moduleIssues: mkStore(),
    viewIssues: mkStore(),
    getFilterExpression: () => (filtered ? { and: [1] } : {}),
    issueDetail: detail,
    onIssueMissingFromPeek: () => calls.push(["toast"]),
  });
  return { applier, calls, retrieved };
}
const tick = async (t, ms) => {
  t.mock.timers.tick(ms);
  for (let i = 0; i < 10; i++) await Promise.resolve(); // oxlint-disable-line no-await-in-loop
};
const ev = (ids, kind = "issue:updated", actor) => {
  const [k, v] = kind.split(":");
  return {
    type: "events",
    project_id: "p",
    items: ids.map((id) => ({ issue_id: id, kinds: [k], verbs: [v], actor_ids: actor ? [actor] : [] })),
  };
};

test("debounce, dedupe, 50-id chunks; new issue is added, missing removed list-first", async (t) => {
  const { applier, calls, retrieved } = setup(t, { present: { gone: { id: "gone" } }, listed: ["gone"] });
  globalThis.__resp = (ids) => ids.filter((i) => i !== "gone").map((id) => ({ id, project_id: "p" }));
  const ids = Array.from({ length: 60 }, (_, i) => "n" + i);
  applier.handle(ev(ids.slice(0, 30)));
  applier.handle(ev([...ids.slice(20), "gone"]));
  await tick(t, 299);
  assert.equal(retrieved.length, 0);
  await tick(t, 2);
  assert.deepEqual(
    retrieved.map((c) => c.length),
    [50, 11]
  );
  assert.equal(calls.filter((c) => c[0] === "addToList").length, 60);
  const rm = calls.findIndex((c) => c[0] === "removeFromList"),
    mrm = calls.findIndex((c) => c[0] === "map.remove");
  assert.ok(rm >= 0 && rm < mrm);
  assert.deepEqual(calls[rm], ["removeFromList", "gone", true], "map entry still present when the list is updated");
});
test("max wait 1 s under a steady event stream", async (t) => {
  const { applier, retrieved } = setup(t);
  globalThis.__resp = () => [];
  for (let i = 0; i < 8; i++) {
    applier.handle(ev(["a" + i]));
    // oxlint-disable-next-line no-await-in-loop
    await tick(t, 200);
  }
  assert.ok(retrieved.length >= 1);
});
test("existing listed issue -> updateIssueList(after, before); cycle scope removal", async (t) => {
  const { applier, calls } = setup(t, {
    route: { cycleId: "c1" },
    present: { a: { id: "a", project_id: "p", cycle_id: "c1" } },
    listed: ["a"],
  });
  globalThis.__resp = () => [{ id: "a", project_id: "p", cycle_id: "c2" }];
  applier.handle(ev(["a"]));
  await tick(t, 400);
  const u = calls.find((c) => c[0] === "updateList");
  assert.deepEqual(u, ["updateList", undefined, "a", "DELETE"]);
});
test("filtered store -> coarse path only, 1 s debounce", async (t) => {
  const { applier, calls } = setup(t, { filtered: true, listed: [] });
  globalThis.__resp = (ids) => ids.map((id) => ({ id, project_id: "p" }));
  applier.handle(ev(["a"]));
  await tick(t, 400);
  assert.equal(calls.filter((c) => c[0] === "addToList").length, 0);
  assert.equal(calls.filter((c) => c[0] === "coarse").length, 0);
  await tick(t, 1000);
  assert.equal(calls.filter((c) => c[0] === "coarse").length, 1);
});
test("full_refresh / resync -> coarse", async (t) => {
  const { applier, calls } = setup(t);
  applier.handle({ type: "resync", project_id: "p" });
  applier.handle({ type: "events", project_id: "p", items: [], full_refresh: true });
  await tick(t, 1000);
  assert.equal(calls.filter((c) => c[0] === "coarse").length, 1);
});
test("peek: missing id closes peek + toast, never fetchIssue", async (t) => {
  const { applier, calls } = setup(t, {
    peek: { projectId: "p", issueId: "i1", workspaceSlug: "w" },
    present: { i1: { id: "i1" } },
  });
  globalThis.__resp = () => [];
  applier.handle(ev(["i1"], "issue:deleted"));
  await tick(t, 400);
  assert.deepEqual(
    calls.filter((c) => ["setPeek", "toast", "fetchIssue"].includes(c[0])),
    [["setPeek", undefined], ["toast"]]
  );
});
test("peek: fetchIssue throttled to 1 per 2 s; comment fallbacks", async (t) => {
  const { applier, calls } = setup(t, {
    peek: { projectId: "p", issueId: "i1", workspaceSlug: "w" },
    present: { i1: { id: "i1", project_id: "p" } },
  });
  globalThis.__resp = (ids) => ids.map((id) => ({ id, project_id: "p" }));
  applier.handle(ev(["i1"], "issue:updated"));
  await tick(t, 400);
  assert.equal(calls.filter((c) => c[0] === "fetchIssue").length, 1);
  applier.handle(ev(["i1"], "comment:updated"));
  await tick(t, 400);
  assert.equal(calls.filter((c) => c[0] === "fetchIssue").length, 1, "throttled");
  assert.ok(calls.some((c) => c[0] === "fetchComments") && calls.some((c) => c[0] === "fetchActivities"));
  await tick(t, 2000);
  assert.equal(calls.filter((c) => c[0] === "fetchIssue").length, 2, "trailing fetch");
});
test("own-actor events are delayed 1.5 s, not dropped", async (t) => {
  const { applier, retrieved } = setup(t);
  globalThis.__resp = () => [];
  applier.handle(ev(["a"], "issue:updated", "me"));
  await tick(t, 1400);
  assert.equal(retrieved.length, 0);
  await tick(t, 400);
  await tick(t, 400);
  assert.equal(retrieved.length, 1);
});

test("comment created refetches incrementally, comment updated resets the cached list first", async (t) => {
  const { applier, calls } = setup(t, {
    peek: { projectId: "p", issueId: "i1", workspaceSlug: "w" },
    present: { i1: { id: "i1", project_id: "p" } },
  });
  globalThis.__resp = (ids) => ids.map((id) => ({ id, project_id: "p" }));
  applier.handle(ev(["i1"], "comment:created"));
  await tick(t, 400);
  assert.equal(calls.filter((c) => c[0] === "fetchIssue").length, 1);
  applier.handle(ev(["i1"], "comment:created"));
  await tick(t, 400);
  assert.deepEqual(
    calls.filter((c) => c[0] === "fetchComments"),
    [["fetchComments", "i1"]]
  );
  applier.handle(ev(["i1"], "comment:deleted"));
  await tick(t, 400);
  assert.equal(calls.filter((c) => c[0] === "fetchComments").length, 2);
});
test("own-actor delay is per item", async (t) => {
  const { applier, retrieved } = setup(t);
  globalThis.__resp = () => [];
  applier.handle({
    type: "events",
    project_id: "p",
    items: [
      { issue_id: "mine", kinds: ["issue"], verbs: ["updated"], actor_ids: ["me"] },
      { issue_id: "theirs", kinds: ["issue"], verbs: ["updated"], actor_ids: ["other"] },
    ],
  });
  await tick(t, 400);
  assert.deepEqual(retrieved, [["theirs"]]);
  await tick(t, 1200);
  await tick(t, 400);
  assert.deepEqual(retrieved, [["theirs"], ["mine"]]);
});
test("revoked closes an open peek and refreshes lists", async (t) => {
  const { applier, calls } = setup(t, { peek: { projectId: "p", issueId: "i1", workspaceSlug: "w" } });
  applier.handle({ type: "revoked", project_id: "p" });
  await tick(t, 1000);
  assert.ok(
    calls.some((c) => c[0] === "setPeek") && calls.some((c) => c[0] === "toast") && calls.some((c) => c[0] === "coarse")
  );
});
