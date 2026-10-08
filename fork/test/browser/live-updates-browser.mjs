// SPDX-License-Identifier: AGPL-3.0-only
//
// live-updates-browser.mjs - two-session headless browser checks for the live events of the
// fork against the local stack (fork/test/local-stack.sh). Run it with
// `local-stack.sh browser --live`.
//
// Session A is an admin browser context that changes data through the app's own web API
// (the calls the UI makes, with the admin session cookie). Session B is a member browser
// context with the work item list, the board and (for S2/S6) a peek open. B is never
// reloaded after it is ready: every change must show up through the live events socket.
//
//   S1 create   a new work item shows up in B (list and board)
//   S2 update   a title change shows in B (list and board); a priority change shows in the peek
//   S3 move     a state change moves the card to the other board column
//   S4 delete   a deleted work item disappears from B (list and board)
//   S5 bulk     five items created at once all show up, then a bulk delete removes all five
//   S6 comment  a comment added by A shows in the peek that B has open
//
// Each check waits at most LIVE_BROWSER_BOUND_MS after the API call returned; the time to
// the first sighting is the latency. The check FAILs when the change is not seen within the
// bound. Prints one "PASS <name>" or "FAIL <name> (<reason>)" line per check, a "NOTE"
// line per scenario with its latency, then a summary and a per-scenario table; exit 0 when
// all pass, 1 when any fails, 2 for a setup problem. Never prints a key or a session.
//
// Environment (required unless marked optional; local-stack.sh sets them):
//   LIVE_BROWSER_BASE_URL        origin of the stack, for example http://localhost:18080
//   LIVE_BROWSER_WORKSPACE       workspace slug
//   LIVE_BROWSER_PROJECT_ID      project id
//   LIVE_BROWSER_ADMIN_SESSION   session cookie value of a project admin (session A)
//   LIVE_BROWSER_MEMBER_SESSION  session cookie value of a project member (session B)
//   LIVE_BROWSER_BOUND_MS        optional, latency bound per check in ms (default 8000)
//   LIVE_BROWSER_ARTIFACTS       optional, screenshot and report directory (default fork/test/artifacts)
//   LIVE_BROWSER_BREAK           optional, "socket": B never gets its events socket (it is
//                                routed to a silent stub), so every "seen live" check must
//                                FAIL (negative check)
//   PLAYWRIGHT_MODULE_DIR        optional, node_modules directory that contains playwright
//   PLAYWRIGHT_CHROMIUM_PATH     optional, path of a chromium binary to launch
//
// Playwright is not a dependency of the workspace; see pages-browser.mjs for how to get it.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const env = (k, d) => process.env[k] ?? d;
const need = (k) => {
  const v = process.env[k];
  if (!v) {
    console.error(`live-updates-browser: ${k} is not set`);
    process.exit(2);
  }
  return v;
};

function loadPlaywright() {
  const dirs = [];
  if (process.env.PLAYWRIGHT_MODULE_DIR) dirs.push(process.env.PLAYWRIGHT_MODULE_DIR);
  dirs.push(here);
  try {
    dirs.push(execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim());
  } catch {
    /* npm missing: only the other locations are tried */
  }
  for (const d of dirs) {
    try {
      return createRequire(join(resolve(d), "noop.js"))("playwright");
    } catch {
      /* try the next location */
    }
  }
  console.error("live-updates-browser: playwright not found (see the header of pages-browser.mjs)");
  process.exit(2);
}

const BASE = need("LIVE_BROWSER_BASE_URL").replace(/\/$/, "");
const SLUG = need("LIVE_BROWSER_WORKSPACE");
const PROJECT = need("LIVE_BROWSER_PROJECT_ID");
const ADMIN_SESSION = need("LIVE_BROWSER_ADMIN_SESSION");
const MEMBER_SESSION = need("LIVE_BROWSER_MEMBER_SESSION");
const BOUND_MS = Number(env("LIVE_BROWSER_BOUND_MS", "8000"));
if (!Number.isFinite(BOUND_MS) || BOUND_MS < 1) {
  console.error("live-updates-browser: LIVE_BROWSER_BOUND_MS must be a positive number");
  process.exit(2);
}
const ART = resolve(env("LIVE_BROWSER_ARTIFACTS", join(here, "..", "artifacts")));
const BREAK = env("LIVE_BROWSER_BREAK", "");
if (BREAK && BREAK !== "socket") {
  console.error(`live-updates-browser: unknown LIVE_BROWSER_BREAK value "${BREAK}"`);
  process.exit(2);
}
const WEB = `/workspaces/${SLUG}/projects/${PROJECT}`;
const ISSUES_URL = `${BASE}/${SLUG}/projects/${PROJECT}/issues/`;
const RUN = Math.random().toString(36).slice(2, 7);

let passes = 0;
let fails = 0;
const table = []; // { sc, name, ok, ms }
const pass = (n) => {
  passes++;
  console.log(`PASS ${n}`);
};
const fail = (n, why) => {
  fails++;
  console.log(`FAIL ${n} (${why})`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- session A: the admin context calls the web API like the UI does
let A; // APIRequestContext of the admin context
async function web(method, path, body) {
  const res = await A.fetch(`${BASE}/api${WEB}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    data: body === undefined ? undefined : JSON.stringify(body),
    timeout: 30000,
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* not json */
  }
  return { status: res.status(), json, text };
}
const mkIssue = async (name, extra = {}) => {
  const r = await web("POST", "/issues/", { name, ...extra });
  return r.status === 201 ? r.json?.id : null;
};

// ---- session B: pages
async function openB(ctx, label) {
  const page = await ctx.newPage();
  const st = { label, subscribed: false, sockets: 0 };
  page.__st = st;
  page.on("websocket", (ws) => {
    if (!ws.url().includes("/live/events")) return;
    st.sockets++;
    ws.on("framereceived", (f) => {
      try {
        if (JSON.parse(f.payload).type === "subscribed") st.subscribed = true;
      } catch {
        /* not json */
      }
    });
  });
  await page.goto(ISSUES_URL, { waitUntil: "domcontentloaded" });
  await page.getByText("lu smoke issue").first().waitFor({ timeout: 45000 }).catch(() => {});
  const t0 = Date.now();
  while (!st.subscribed && Date.now() - t0 < 15000) await sleep(200);
  await sleep(500);
  await page.evaluate(() => {
    window.__liveNoReload = true;
  });
  return page;
}

// waitSeen(page, fn): ms until `fn(page)` (a Playwright wait) succeeds, -1 when over the bound
async function timed(fn) {
  const t = Date.now();
  try {
    await fn(BOUND_MS);
    return Date.now() - t;
  } catch {
    return -1;
  }
}
const appears = (page, text) => timed((to) => page.getByText(text).first().waitFor({ timeout: to }));
const gone = (page, text) => timed((to) => page.getByText(text).first().waitFor({ state: "detached", timeout: to }));

// column of a board card: the header whose left edge is the closest at or before the card's
const columnOf = (page, text) =>
  page.evaluate(
    ({ text, names }) => {
      const left = (t) => {
        const el = [...document.querySelectorAll("*")].find((e) => e.children.length === 0 && e.textContent.trim() === t);
        return el ? Math.round(el.getBoundingClientRect().left) : undefined;
      };
      const cx = left(text);
      if (cx === undefined) return null;
      let best = null;
      let bx = -1;
      for (const n of names) {
        const x = left(n);
        if (x !== undefined && x <= cx + 20 && x > bx) {
          best = n;
          bx = x;
        }
      }
      return best;
    },
    { text, names: ["Backlog", "Todo", "In Progress", "Done", "Cancelled"] },
  );

async function shot(page, name) {
  try {
    await page.screenshot({ path: join(ART, `live-${name}.png`) });
  } catch (e) {
    console.log(`NOTE screenshot ${name} failed: ${e.message.split("\n")[0]}`);
  }
}

// ---- scenario bookkeeping
const lat = {}; // sc -> [ms...]
function seen(sc, name, ms, extra = "") {
  const ok = ms >= 0;
  (lat[sc] ??= []).push(ok ? ms : null);
  table.push({ sc, name, ok, ms: ok ? ms : null });
  const label = `S${sc} ${name}`;
  if (ok) pass(`${label}: seen live after ${ms} ms (bound ${BOUND_MS} ms)${extra}`);
  else fail(label, `not seen live within ${BOUND_MS} ms without a reload${extra}`);
}
// a check that cannot run because its starting point was never seen live: FAIL, never a vacuous PASS
function noStart(sc, name, what) {
  table.push({ sc, name, ok: false, ms: null });
  (lat[sc] ??= []).push(null);
  fail(`S${sc} ${name}`, `${what}: not seen live within ${BOUND_MS} ms, so the check cannot start`);
}
function note(sc, title) {
  const v = lat[sc] ?? [];
  const ok = v.length > 0 && v.every((x) => x !== null);
  console.log(`NOTE S${sc} ${title} latency ms: ${v.map((x) => (x === null ? "over bound" : x)).join(" / ") || "-"}${ok ? "" : " (not all seen)"}`);
}

async function peekOpen(page, name) {
  try {
    await page.getByText(name).first().click({ timeout: 10000 });
    await page.getByText("Properties", { exact: true }).first().waitFor({ timeout: 15000 });
    return true;
  } catch {
    return false;
  }
}

async function main() {
  mkdirSync(ART, { recursive: true });
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH || undefined,
    args: ["--no-sandbox"],
  });
  const ctxA = await browser.newContext({ viewport: { width: 1400, height: 900 } });
  await ctxA.addCookies([{ name: "session-id", value: ADMIN_SESSION, url: BASE }]);
  A = ctxA.request;
  // tall viewport: the board only renders the cards that are in view
  const ctxB = await browser.newContext({ viewport: { width: 1400, height: 2400 } });
  await ctxB.addCookies([{ name: "session-id", value: MEMBER_SESSION, url: BASE }]);
  if (BREAK === "socket") await ctxB.routeWebSocket(/\/live\/events/, () => {});
  const created = [];
  const bProps = async (display_filters) => {
    const r = await fetch(`${BASE}/api${WEB}/user-properties/`, {
      method: "PATCH",
      headers: { Cookie: `session-id=${MEMBER_SESSION}`, "Content-Type": "application/json" },
      body: JSON.stringify({ display_filters }),
      signal: AbortSignal.timeout(30000),
    });
    return r.status;
  };
  try {
    const states = Object.fromEntries(((await web("GET", "/states/")).json ?? []).map((s) => [s.name, s.id]));
    if (!states.Backlog || !states.Todo) {
      fail("setup: project states Backlog and Todo", "not found");
      return;
    }
    // B: one page on the list layout and one on the board, both opened before any change
    const l1 = await bProps({ layout: "list", group_by: null });
    const listPage = await openB(ctxB, "list");
    const l2 = await bProps({ layout: "kanban", group_by: "state" });
    const boardPage = await openB(ctxB, "board");
    if (l1 !== 200 || l2 !== 200) {
      fail("setup: set the layout of session B", `http ${l1}/${l2}`);
      return;
    }
    const connected = listPage.__st.subscribed && boardPage.__st.subscribed;
    if (connected) pass("B pages opened and subscribed to the live events socket");
    else fail("B pages opened and subscribed to the live events socket", `list=${listPage.__st.subscribed} board=${boardPage.__st.subscribed}`);
    await shot(boardPage, "b-board-ready");

    // ---- S1 create
    const n1 = `lu-s1-${RUN}`;
    const id1 = await mkIssue(n1, { state: states.Backlog });
    if (!id1) fail("S1 create", "the admin API call did not answer 201");
    else {
      created.push(id1);
      const [a, b] = await Promise.all([appears(listPage, n1), appears(boardPage, n1)]);
      seen(1, "create (list)", a);
      seen(1, "create (board)", b);
    }
    note(1, "create");

    // ---- S2 update: title on both pages, priority in the peek of the list page
    const n2 = `lu-s2-${RUN}`;
    const id2 = await mkIssue(n2, { state: states.Backlog });
    if (!id2) fail("S2 update", "the admin API call did not answer 201");
    else {
      created.push(id2);
      await Promise.all([appears(listPage, n2), appears(boardPage, n2)]);
      const n2b = `lu-s2-renamed-${RUN}`;
      const r = await web("PATCH", `/issues/${id2}/`, { name: n2b });
      if (![200, 204].includes(r.status)) fail("S2 update title", `PATCH answered http ${r.status}`);
      else {
        const [a, b] = await Promise.all([appears(listPage, n2b), appears(boardPage, n2b)]);
        seen(2, "title (list)", a);
        seen(2, "title (board)", b);
      }
      if (await peekOpen(listPage, n2b)) {
        const before = await listPage.getByText("High", { exact: true }).count();
        const p = await web("PATCH", `/issues/${id2}/`, { priority: "high" });
        if (![200, 204].includes(p.status) || before !== 0) fail("S2 update priority", `PATCH http ${p.status}, "High" shown before: ${before}`);
        else seen(2, "priority (peek)", await appears(listPage, "High"));
        await shot(listPage, "s2-peek");
        await listPage.keyboard.press("Escape");
      } else {
        fail("S2 update priority", "the peek did not open");
      }
    }
    note(2, "update");

    // ---- S3 move: Backlog -> Todo -> In Progress on the board
    const n3 = `lu-s3-${RUN}`;
    const id3 = await mkIssue(n3, { state: states.Backlog });
    if (!id3) fail("S3 move", "the admin API call did not answer 201");
    else {
      created.push(id3);
      const seen3 = (await appears(boardPage, n3)) >= 0;
      const start = seen3 ? await columnOf(boardPage, n3) : null;
      if (!seen3) noStart(3, "move", "the new item");
      else if (start !== "Backlog") fail("S3 move", `the card starts in column ${start}, not Backlog`);
      else {
        for (const target of ["Todo", "In Progress"]) {
          const r = await web("PATCH", `/issues/${id3}/`, { state: states[target] });
          if (![200, 204].includes(r.status)) {
            fail(`S3 move to ${target}`, `PATCH answered http ${r.status}`);
            continue;
          }
          const t = Date.now();
          let col = null;
          while (Date.now() - t < BOUND_MS) {
            col = await columnOf(boardPage, n3);
            if (col === target) break;
            await sleep(100);
          }
          seen(3, `move to ${target} (board column)`, col === target ? Date.now() - t : -1, col === target ? "" : `; card in ${col}`);
        }
      }
    }
    await shot(boardPage, "s3-board-after");
    note(3, "move");

    // ---- S4 delete
    const n4 = `lu-s4-${RUN}`;
    const id4 = await mkIssue(n4, { state: states.Backlog });
    if (!id4) fail("S4 delete", "the admin API call did not answer 201");
    else {
      const pre4 = await Promise.all([appears(listPage, n4), appears(boardPage, n4)]);
      if (pre4.includes(-1)) noStart(4, "delete", "the new item");
      const r = await web("DELETE", `/issues/${id4}/`);
      if (pre4.includes(-1)) {
        /* reported above */
      } else if (r.status !== 204) fail("S4 delete", `DELETE answered http ${r.status}`);
      else {
        const [a, b] = await Promise.all([gone(listPage, n4), gone(boardPage, n4)]);
        seen(4, "delete (list)", a);
        seen(4, "delete (board)", b);
      }
    }
    note(4, "delete");

    // ---- S5 bulk: five at once, then a bulk delete of the five
    const names5 = Array.from({ length: 5 }, (_, i) => `lu-s5-${i}-${RUN}`);
    const ids5 = (await Promise.all(names5.map((n) => mkIssue(n, { state: states.Backlog })))).filter(Boolean);
    if (ids5.length !== 5) fail("S5 bulk", `only ${ids5.length} of 5 items were created`);
    else {
      created.push(...ids5);
      const t = Date.now();
      const all = (page) => Promise.all(names5.map((n) => appears(page, n))).then((v) => (v.includes(-1) ? -1 : Date.now() - t));
      const [a, b] = await Promise.all([all(listPage), all(boardPage)]);
      seen(5, "bulk create of 5 (list)", a);
      seen(5, "bulk create of 5 (board)", b);
      const d = await web("DELETE", "/bulk-delete-issues/", { issue_ids: ids5 });
      if (a < 0 || b < 0) noStart(5, "bulk delete of 5", "the five new items");
      else if (d.status !== 200) fail("S5 bulk delete", `bulk delete answered http ${d.status}`);
      else {
        const t2 = Date.now();
        const none = (page) => Promise.all(names5.map((n) => gone(page, n))).then((v) => (v.includes(-1) ? -1 : Date.now() - t2));
        const [c, e] = await Promise.all([none(listPage), none(boardPage)]);
        seen(5, "bulk delete of 5 (list)", c);
        seen(5, "bulk delete of 5 (board)", e);
      }
    }
    note(5, "bulk");

    // ---- S6 comment in the peek
    const n6 = `lu-s6-${RUN}`;
    const id6 = await mkIssue(n6, { state: states.Backlog });
    if (!id6) fail("S6 comment", "the admin API call did not answer 201");
    else {
      created.push(id6);
      const pre6 = await appears(listPage, n6);
      if (pre6 < 0) noStart(6, "comment", "the new item");
      else if (!(await peekOpen(listPage, n6))) fail("S6 comment", "the peek did not open");
      else {
        const text = `lu-s6-comment-${RUN}`;
        const r = await web("POST", `/issues/${id6}/comments/`, { comment_html: `<p>${text}</p>` });
        if (r.status !== 201) fail("S6 comment", `POST answered http ${r.status}`);
        else seen(6, "comment (peek)", await appears(listPage, text));
        await shot(listPage, "s6-peek");
      }
    }
    note(6, "comment");

    // B must never have been reloaded: the marker set after the page was ready is still there
    const marks = await Promise.all([listPage, boardPage].map((p) => p.evaluate(() => window.__liveNoReload === true).catch(() => false)));
    if (BREAK === "socket") console.log(`NOTE B reload marker intact: ${marks.join("/")}`);
    else if (marks.every(Boolean)) pass("B pages were never reloaded during the run");
    else fail("B pages were never reloaded during the run", "a page navigated or reloaded");
  } finally {
    try {
      // best-effort cleanup of the items left behind, then restore the layout of B
      if (created.length) await web("DELETE", "/bulk-delete-issues/", { issue_ids: created });
      await bProps({ layout: "list", group_by: null });
    } catch {
      /* the stack is throwaway */
    }
    await browser.close();
  }
}

try {
  await main();
} catch (e) {
  fail("browser run", String(e.message ?? e).split("\n")[0]);
}

const names = { 1: "create", 2: "update", 3: "move", 4: "delete", 5: "bulk", 6: "comment" };
const rows = Object.keys(names).map((sc) => {
  const t = table.filter((r) => String(r.sc) === sc);
  const ok = t.length > 0 && t.every((r) => r.ok);
  const ms = t.filter((r) => r.ok).map((r) => r.ms);
  return { scenario: `S${sc} ${names[sc]}`, result: ok ? "PASS" : "FAIL", checks: t.length, max_ms: ms.length ? Math.max(...ms) : null };
});
console.log(`BOUND ${BOUND_MS} ms${BREAK ? ` (break=${BREAK})` : ""}`);
for (const r of rows) console.log(`SCENARIO ${r.scenario.padEnd(11)} ${r.result}  checks=${r.checks}  max latency=${r.max_ms === null ? "-" : r.max_ms + " ms"}`);
try {
  writeFileSync(join(ART, "live-updates-report.json"), JSON.stringify({ bound_ms: BOUND_MS, break: BREAK || null, scenarios: rows, checks: table }, null, 2));
} catch {
  /* the report file is a convenience */
}
console.log(`BROWSER SUMMARY: ${passes} passed, ${fails} failed${BREAK ? ` (break=${BREAK})` : ""}`);
process.exit(fails === 0 ? 0 : 1);
