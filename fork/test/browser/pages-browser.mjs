// SPDX-License-Identifier: AGPL-3.0-only
//
// pages-browser.mjs - headless browser checks for the fork pages API against the local
// stack (fork/test/local-stack.sh). Run it with `local-stack.sh smoke --browser`.
//
//   P4  PATCH of a page API answers the exact 409 while the page is open in an editor,
//       and 200 after every tab of it is closed.
//   P3  reopening the page afterwards shows the PATCHed text exactly once (and the old
//       text not at all), also on a second reopen.
//
// Prints one "PASS <name>" or "FAIL <name> (<reason>)" line per check, then a summary;
// exit 0 when all pass, 1 when any fails, 2 for a setup problem. Never prints a key.
//
// Environment (all required unless marked optional; local-stack.sh sets them):
//   PAGES_BROWSER_BASE_URL       origin of the stack, for example http://localhost:18080
//   PAGES_BROWSER_WORKSPACE      workspace slug
//   PAGES_BROWSER_PROJECT_ID     project id
//   PAGES_BROWSER_MEMBER_KEY     API key of a project member (header X-API-Key)
//   PAGES_BROWSER_MEMBER_SESSION session cookie value of the same member
//   PAGES_BROWSER_ARTIFACTS      optional, screenshot directory (default fork/test/artifacts)
//   PAGES_BROWSER_CLOSE_WAIT_S   optional, seconds to wait for 200 after closing (default 40)
//   PAGES_BROWSER_BREAK          optional, "presence": the browser never connects its
//                                collaboration socket, so live never sees the page as
//                                open; the 409 check must then FAIL (negative check)
//   PLAYWRIGHT_MODULE_DIR        optional, node_modules directory that contains playwright
//   PLAYWRIGHT_CHROMIUM_PATH     optional, path of a chromium binary to launch
//
// Playwright is not a dependency of the workspace. Install it once, outside the repo
// (for example `npm install -g playwright@1.56.1` and a matching chromium), or point
// PLAYWRIGHT_MODULE_DIR at an existing install.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const env = (k, d) => process.env[k] ?? d;
const need = (k) => {
  const v = process.env[k];
  if (!v) {
    console.error(`pages-browser: ${k} is not set`);
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
  console.error("pages-browser: playwright not found (see the header of this file)");
  process.exit(2);
}

const BASE = need("PAGES_BROWSER_BASE_URL").replace(/\/$/, "");
const SLUG = need("PAGES_BROWSER_WORKSPACE");
const PROJECT = need("PAGES_BROWSER_PROJECT_ID");
const KEY = need("PAGES_BROWSER_MEMBER_KEY");
const SESSION = need("PAGES_BROWSER_MEMBER_SESSION");
const ART = resolve(env("PAGES_BROWSER_ARTIFACTS", join(here, "..", "artifacts")));
const CLOSE_WAIT_S = Number(env("PAGES_BROWSER_CLOSE_WAIT_S", "40"));
const BREAK = env("PAGES_BROWSER_BREAK", "");
if (BREAK && BREAK !== "presence") {
  console.error(`pages-browser: unknown PAGES_BROWSER_BREAK value "${BREAK}"`);
  process.exit(2);
}
const API = `${BASE}/api/v1/workspaces/${SLUG}/projects/${PROJECT}`;
const EXPECTED_409 = "page is open in an editor; retry later";
const RUN = Math.random().toString(36).slice(2, 8);
const ORIGINAL = `pw-original-${RUN}`;
const CHANGED = `pw-changed-${RUN}`;

let passes = 0;
let fails = 0;
const pass = (n) => {
  passes++;
  console.log(`PASS ${n}`);
};
const fail = (n, why) => {
  fails++;
  console.log(`FAIL ${n} (${why})`);
};
const check = (n, ok, why) => (ok ? pass(n) : fail(n, why));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { "X-API-Key": KEY, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* not json */
  }
  return { status: res.status, text, json };
}

const occurrences = (hay, needle) => hay.split(needle).length - 1;

async function editorText(page) {
  const parts = await page.locator(".ProseMirror").allInnerTexts();
  return parts.join("\n");
}

async function openPage(browser, pageId, tag) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await ctx.addCookies([{ name: "session-id", value: SESSION, url: BASE }]);
  if (BREAK === "presence") await ctx.routeWebSocket(/\/live\/collaboration/, () => {});
  const page = await ctx.newPage();
  let collab = false;
  page.on("websocket", (ws) => {
    if (ws.url().includes("/live/collaboration")) collab = true;
  });
  await page.goto(`${BASE}/${SLUG}/projects/${PROJECT}/pages/${pageId}/`, { waitUntil: "domcontentloaded" });
  return { ctx, page, tag, collab: () => collab };
}

async function shot(page, name) {
  try {
    await page.screenshot({ path: join(ART, `${name}.png`) });
  } catch (e) {
    console.log(`NOTE screenshot ${name} failed: ${e.message.split("\n")[0]}`);
  }
}

async function main() {
  mkdirSync(ART, { recursive: true });
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH || undefined,
    args: ["--no-sandbox"],
  });
  try {
    const created = await api("POST", "/pages/", { name: `pw page ${RUN}`, description_html: `<p>${ORIGINAL}</p>` });
    if (created.status !== 201 || !created.json?.id) {
      fail("setup: create the test page", `http ${created.status}`);
      return;
    }
    const id = created.json.id;
    const patchBody = { description_html: `<p>${CHANGED}</p>` };

    // ---- P4: while open
    const a = await openPage(browser, id, "open");
    if (BREAK === "presence") {
      await sleep(8000);
    } else {
      try {
        await a.page.locator(".ProseMirror", { hasText: ORIGINAL }).first().waitFor({ timeout: 30000 });
        await sleep(2000); // let the collaboration session register
        check("P4 browser opened the page through the collaboration socket", a.collab(), "no collaboration websocket seen");
      } catch {
        fail("P4 browser opened the page", "editor did not show the page text within 30 s");
      }
    }
    await shot(a.page, "p4-open-editor");
    const whileOpen = await api("PATCH", `/pages/${id}/`, patchBody);
    const exact =
      whileOpen.status === 409 &&
      whileOpen.json !== null &&
      Object.keys(whileOpen.json).join() === "error" &&
      whileOpen.json.error === EXPECTED_409;
    check("P4 PATCH while the page is open: exact 409", exact, `http ${whileOpen.status} ${whileOpen.text.slice(0, 120)}`);
    if (whileOpen.status === 200) {
      // the change went through although the page is open; the later steps still run
      console.log("NOTE the PATCH was accepted while the page was open");
    } else {
      const still = await api("GET", `/pages/${id}/`);
      check(
        "P4 the refused PATCH wrote nothing",
        still.status === 200 && still.text.includes(ORIGINAL) && !still.text.includes(CHANGED),
        `http ${still.status}`,
      );
    }

    // ---- P4: after closing
    await a.ctx.close();
    let afterClose = whileOpen.status === 200 ? whileOpen : null;
    const t0 = Date.now();
    while (afterClose === null && Date.now() - t0 < CLOSE_WAIT_S * 1000) {
      const r = await api("PATCH", `/pages/${id}/`, patchBody);
      if (r.status !== 409) afterClose = r;
      else await sleep(1000);
    }
    const waited = ((Date.now() - t0) / 1000).toFixed(1);
    check(
      `P4 PATCH after the page is closed: 200 (after ${waited}s)`,
      afterClose !== null && afterClose.status === 200,
      afterClose ? `http ${afterClose.status} ${afterClose.text.slice(0, 120)}` : `still 409 after ${CLOSE_WAIT_S} s`,
    );

    // ---- P3: reopen shows the change exactly once
    for (const n of [1, 2]) {
      const b = await openPage(browser, id, `reopen${n}`);
      let text = "";
      try {
        await b.page.locator(".ProseMirror", { hasText: CHANGED }).first().waitFor({ timeout: 30000 });
        await sleep(4000); // late syncs would show up as a second copy
        text = await editorText(b.page);
      } catch {
        text = await editorText(b.page).catch(() => "");
      }
      await shot(b.page, `p3-reopen-${n}`);
      const copies = occurrences(text, CHANGED);
      check(`P3 reopen ${n}: the change shows exactly once`, copies === 1, `${copies} copies`);
      check(`P3 reopen ${n}: the old text is gone`, occurrences(text, ORIGINAL) === 0, `${occurrences(text, ORIGINAL)} copies of the old text`);
      await b.ctx.close();
      if (n === 1) await sleep(3000);
    }
    const final = await api("GET", `/pages/${id}/`);
    check(
      "P3 stored html has the change exactly once",
      final.status === 200 && occurrences(final.text, CHANGED) === 1,
      `http ${final.status} ${occurrences(final.text, CHANGED)} copies`,
    );
  } finally {
    await browser.close();
  }
}

try {
  await main();
} catch (e) {
  fail("browser run", String(e.message ?? e).split("\n")[0]);
}
console.log(`BROWSER SUMMARY: ${passes} passed, ${fails} failed${BREAK ? ` (break=${BREAK})` : ""}`);
process.exit(fails === 0 ? 0 : 1);
