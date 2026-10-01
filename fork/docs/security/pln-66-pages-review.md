# PLN-66: security review of the pages API and live presence endpoints

Scope: base `live-updates/v1.4.2` at `22a3d000`. Review only; no code was changed.

Files reviewed:

- `apps/api/plane/api/views/page.py`
- `apps/api/plane/api/serializers/page.py`
- `apps/api/plane/api/urls/page.py`
- `apps/api/plane/app/permissions/page.py`
- `apps/api/plane/utils/live_pages.py`
- `apps/api/plane/utils/content_validator.py` (sanitiser)
- `apps/live/src/fork-pages/` (`auth.ts`, `pages.controller.ts`, `rebase.ts`)
- `packages/decorators/src/controller.ts` (middleware order)

Line numbers refer to the base commit.

## Summary

Origin: `fork` = code added by this fork; `upstream` = unchanged from the upstream base (documented only, not fixed here); `mixed` = both.

| ID  | Severity | Origin   | Title                                                                                                                         | Blocks deploy                        |
| --- | -------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| F1  | High     | fork     | A single PATCH can block the live service event loop for seconds to minutes                                                   | Yes (while the pages API flag is on) |
| F2  | Low      | upstream | A page owner keeps write and archive rights after demotion to guest                                                           | No                                   |
| F3  | Medium   | fork     | PATCH holds a row lock and a worker across two live HTTP calls                                                                | No (fix with F1)                     |
| F4  | Medium   | fork     | Presence check is best effort; an editor can open the page between check and commit                                           | No                                   |
| F5  | Low      | fork     | The external id 409 discloses the id of private pages of other users                                                          | No                                   |
| F6  | Low      | fork     | `parent` accepts another user's private page and acts as an existence oracle                                                  | No                                   |
| F7  | Low      | upstream | Archive cascades to every descendant regardless of visibility                                                                 | No                                   |
| F8  | Low      | fork     | The example shared secret is accepted by the live service                                                                     | No                                   |
| F9  | Low      | fork     | Unauthenticated status codes on the live endpoints reveal configuration                                                       | No                                   |
| F10 | Low      | fork     | 409 and 503 paths: write blocking and availability coupling to live                                                           | No                                   |
| F11 | Low      | mixed    | Input bounds: no size limit without Content-Length and unbounded `name` (fork); double HTML parse in the sanitiser (upstream) | No                                   |
| F12 | Low      | upstream | The sanitiser allows `style` unfiltered                                                                                       | No                                   |
| F13 | Info     | n/a      | Positive findings (controls verified)                                                                                         | n/a                                  |
| F14 | Info     | n/a      | Minor observations                                                                                                            | n/a                                  |
| N1  | Low      | upstream | Other live routes: non-constant-time key compare and unthrottled failure log                                                  | No                                   |
| N2  | Low      | fork     | The live client follows redirects and would forward the shared key                                                            | No                                   |
| N3  | Info     | fork     | Shared key rotation needs a coordinated restart                                                                               | n/a                                  |

Only F1 should block the deploy. F3 and F4 should be scheduled right after. Upstream items are documented only and are not fixed in this fork.

## Findings

### F1 High (fork): a single PATCH can block the live service event loop

- Where: `apps/live/src/fork-pages/rebase.ts:69` (`generateJSON`) and `:73` (`replaceFragment`); called synchronously from `apps/live/src/fork-pages/pages.controller.ts:96-102`; triggered by `apps/api/plane/api/views/page.py:258`.
- Scenario: any project admin or member (a guest only on pages they own, see F2) PATCHes a page that has a stored binary document with a large `description_html`. The caps do not bound the work: the API caps the body at 5 MB (`FILE_SIZE_LIMIT`, from Content-Length), the sanitiser at 10 MB and the live service accepts 25 MB, and 5 MB is already enough for a stall of over a minute. The only preconditions are that the page has a stored binary and is not open in an editor. The live service converts it on its single Node event loop. The work is synchronous, has no timeout, no concurrency cap and no worker thread. While it runs, the live service serves nothing else: collaborative editing sockets, the presence endpoint and the events hub all stall. The API's 10 s client timeout abandons the request but does not stop the work in live.
- Evidence (measured, local, `rebase()` called directly): 100 KB html, 0.4 s; 1 MB html, 5.0 s; 4.8 MB html, 86.6 s. Cost grows faster than linearly. A second, independent probe (peer review) measured 100 KB 0.5 s, 256 KB 0.6 s and 1 MB 6.5 s, the same order of magnitude. The API rate limit (60 requests per minute per key, `API_KEY_RATE_LIMIT`) is far above what is needed to keep the loop saturated.
- Recommended fix: (1) cap `description_html` on this endpoint to a small value (suggest 256 KB, configurable) and return 413 above it; (2) run the rebase in a worker thread or child process with a timeout and a concurrency limit of 1 to 2, answering 503 with `Retry-After` when full; (3) add a per-page-id single-flight guard so repeated PATCHes of the same page cannot queue.
- Interim mitigation until the fix lands: keep `PAGES_API_ENABLED` off, or enforce a 256 KB cap on `description_html` (0.6 s in the peer probe).
- Blocks deploy: yes, while the pages API flag is on.

### F2 Low (upstream): owner keeps write access after demotion to guest

- Where: `apps/api/plane/app/permissions/page.py:57-59` (owner short-circuit returns True before the role check at `:66`); affects `PageDetailAPIEndpoint.patch` (`page.py:216`) and `PageArchiveAPIEndpoint` (`page.py:329`, `:343`).
- Scenario: a user who owns a page is later demoted to guest in the project (still an active member). For their own pages the permission class returns True for PATCH, archive and unarchive. Verified with a throwaway test: guest-owner PATCH returns 200 and guest-owner archive returns 200, although guests are denied PATCH and archive on other users' pages and denied POST.
- Origin: the permission class is unchanged from upstream and the fork endpoints reuse it; the same behaviour exists in the stock app. Impact is limited to pages the demoted user owns. Document only.
- Recommended fix (if ever taken upstream): apply the role check to the owner too (owner and role in admin or member for write methods; guests read-only). Add a regression test for the guest-owner case.

### F3 Medium: row lock and worker held across live calls

- Where: `apps/api/plane/api/views/page.py:232-271` (`transaction.atomic` plus `select_for_update`, then `rebase_page` with a 10 s timeout and `is_page_loaded` with a 3 s timeout).
- Scenario: each PATCH of a binary page can hold a database row lock, a transaction and a gunicorn worker for up to about 13 s while live is slow (which F1 makes easy to cause). Concurrent PATCHes of the same page queue on the lock; many pages exhaust workers and connections.
- Recommended fix: do the live calls before opening the transaction (read binary, call live, then lock and re-verify `updated_at` or a version before saving; return 409 on change), or lower the timeouts and add the F1 concurrency limit. Prefer an optimistic version check.

### F4 Medium: presence check is best effort

- Where: `apps/api/plane/api/views/page.py:245` and `:270` (check), `:288-293` (save and commit), `:311-316` (post-commit warning only); `apps/live/src/fork-pages/pages.controller.ts:73`.
- Scenario: the check and the database commit are not atomic with the live service. An editor can load the page (reading the old binary) after the check and before the commit. The API write is then silently superseded or merged inconsistently when the editor saves. The code only logs a warning afterwards.
- Recommended fix: make live the writer (live endpoint that takes a per-document lock, rebases, stores and refuses if the document loaded meanwhile), or have the live load path refuse or re-read when a write lock is set for the page. At minimum document the window and return a response field telling the client the write may be superseded.

### F5 Low: external id 409 discloses ids of private pages

- Where: `apps/api/plane/api/views/page.py:158-176`.
- Scenario: the duplicate lookup is not filtered by page visibility. A member POSTing an `external_id` and `external_source` that match another user's private page in the project receives 409 with that page's `id`. Verified with a throwaway test (409 and the id of the private page).
- Recommended fix: scope the duplicate lookup like `base_queryset` (owned by the caller or public); for hidden matches return a generic 409 without `id`, or treat the pair as unique per owner.

### F6 Low: `parent` accepts a private page of another user

- Where: `apps/api/plane/api/serializers/page.py:73-86`.
- Scenario: the parent only needs an active link to the project. A member can attach a new page under another user's private page (201 in the throwaway test), and the response differs from an unknown id (400 "Parent page does not belong to this project."), so private page ids can be probed (ids are UUIDs, so practical impact is small).
- Recommended fix: require the parent to be visible to the caller (reuse `base_queryset`), and return the same error for hidden and unknown parents. Also reject an archived parent.

### F7 Low (upstream): archive cascades to all descendants

- Where: `apps/api/plane/api/views/page.py:340` calling `apps/api/plane/app/views/page/base.py:59-72` (recursive SQL with no project, owner or visibility filter).
- Scenario: an owner or admin who archives a page also archives all descendants, including private pages owned by other users (verified). Unarchive restores them all too.
- Origin: the cascade function is upstream; the fork archive endpoint only calls it. Document only.
- Recommended fix: restrict the cascade to descendants in the same project and not private to other users, or refuse when hidden descendants exist.

### F8 Low: example secret accepted by live

- Where: `apps/live/src/fork-pages/auth.ts:9` and `:30` (only `change-this-key-on-deployment` is rejected); `apps/api/.env.example:66` and `apps/live/.env.example:9` use `secret-key`; the API side sends an empty header when the variable is unset (`apps/api/plane/utils/live_pages.py:39-40`).
- Scenario: a deployment that copies an example file runs with a publicly known key, and the pages endpoints (presence and rebase) accept it from anything that can reach the live service on the internal network.
- Recommended fix: reject known example values and keys shorter than 32 characters at startup (live) and when the API reads the variable, and fail closed with a clear log line naming the variable (not its value).

### F9 Low: unauthenticated status codes reveal configuration

- Where: `apps/live/src/fork-pages/auth.ts:24-38`.
- Scenario: before the key is checked, callers can tell whether the feature flag is on (404 vs other), whether the key is unset or still the placeholder (503), and whether a forwarding header is present (403). The 403 forwarded-header check also runs before the key check.
- Recommended fix: check the key first and answer 404 for every failure on a request carrying forwarding headers; keep the specific causes in an internal log line without the key.

### F10 Low: 409 and 503 paths

- Where: `apps/api/plane/api/views/page.py:42-43`, `:245-246`, `:264-271`; `apps/api/plane/utils/live_pages.py:43-61`.
- Disclosure: a caller who may PATCH the page learns one boolean (open in an editor or not). The response never contains who, how many, or when. Private pages are visible to the owner only. Acceptable.
- Write blocking: any member who can open a public page in the editor keeps its document loaded, so integration writes get 409 for as long as the socket stays open. This is intended behaviour, but it is also a cheap way for a member to stall an integration. Add a `Retry-After` header and keep the message generic.
- Availability coupling: presence unknown (live down, `LIVE_URL` unset, bad answer) returns 409 even for pages with no stored binary; a rebase failure returns 503. Fail-closed is the right default for integrity. Document that a live outage stops all page writes through this API.
- The 409 and 503 bodies contain only fixed strings; no exception text, URL or secret leaks.

### F11 Low (mixed): input bounds

- Where: `apps/api/plane/api/views/page.py:73-80` (`check_body_size` trusts `CONTENT_LENGTH`; a request without it, for example chunked, is not capped here); `apps/api/plane/api/serializers/page.py:60` and `:99` (`name` has no `max_length`; a 1 MB name was accepted, 201); `apps/api/plane/utils/content_validator.py:185-186` (the sanitiser parses the input and the output again with BeautifulSoup to build a warning diff on every request).
- Scenario: memory and CPU amplification by an authenticated member. The shipped reverse proxy config sets a request body limit equal to `FILE_SIZE_LIMIT`, which mitigates the chunked case when it is deployed in front. CPU cost of the double parse was not measured.
- Origin: the Content-Length trust and the unbounded `name` are fork code; the sanitiser double parse is upstream (document only).
- Recommended fix: enforce the cap by reading a bounded stream, add `max_length` (suggest 255) to `name` on create and update, and compute the sanitiser diff only when a log level asks for it.

### F12 Low (upstream): `style` allowed unfiltered

- Where: `apps/api/plane/utils/content_validator.py:82-96` (`style` allowed on all tags).
- Scenario: nh3 does not filter CSS values. `<p style="background:url(//host/x)">` survives sanitising (verified), so a page can trigger third-party requests when rendered (tracking beacon) and can use CSS for overlay or clickjacking style tricks. Script execution is not possible: `javascript:` in `href`, `src` of `img` and of `image-component` and `on*` handlers are all removed (verified).
- Origin: upstream sanitiser configuration. Document only.
- Recommended fix: drop `style` from the generic allowlist, or restrict it to the specific properties the editor emits (colours) with a CSS filter.

### F13 Info: controls verified working

- Project scoping and IDOR: `has_permission` and `base_queryset` both require an active `ProjectPage` link for the url project, the workspace slug and active membership. A page of another project, an unknown id and another user's private page all give the same 403 (no existence oracle). Guests see only their own pages unless `guest_view_all_features`. Archived project, archived page and locked page are refused on write. Existing tests cover these.
- Authentication: API key only (`BaseAPIView.authentication_classes`), so there is no cookie or CSRF exposure; per-key throttle applies.
- Secret handling: the live side compares SHA-256 digests with `timingSafeEqual` (no length leak, no throw); the secret is never logged by either side (log lines carry page id and exception type only; covered by a test); the live logger records method, url, status and time only.
- Middleware order on the live rebase route: decorators evaluate bottom-up, so the access check runs before the body is read (verified by reading `controller.ts:61-70`; no existing test asserts the order, so add one); unauthenticated callers cannot make the service buffer 25 MB.
- Input validation on live: page id must be a UUID; base64 pattern and length checked; binary capped at 10 MB; error bodies echo field paths only.
- Sanitising in and out of the API: html is sanitised on create and PATCH, and the html returned by live in the binary path is re-validated through `PageBinaryUpdateSerializer`, which sanitises it and size-checks the binary before storing.
- Duplicate external pair creation is serialised with an advisory lock.
- Reverse proxy: forwarded headers are set by the shipped Caddy config, so the 403 forwarded-header guard fires for traffic that arrives through the public path.

### F14 Info: minor observations

- Output html on GET is not re-sanitised; safety relies on all writers sanitising and on client escaping. Consider a defence-in-depth pass on read for rows written by other paths.
- `id` and `class` are allowed on all tags (DOM clobbering risk is theoretical).
- Each rejected html logs a warning with tag and attribute names; an attacker can inflate log volume.
- PATCH does not check `project.page_view` (POST does).
- The API and live talk plain HTTP over the internal network; the shared key crosses it in a header. Fine on a private network, note it in deployment docs.
- The live presence route accepts uppercase UUIDs but the document map is keyed by lowercase ids, so a direct caller using uppercase gets a false negative. The API always sends lowercase.
- No optimistic concurrency token on PATCH: concurrent integrations overwrite each other (last writer wins).
- The error message for a non-owner member archiving is 400 while unarchive is 403; cosmetic.

### N1 Low (upstream): other live routes compare the key without constant time and log every failure

- Where: `apps/live/src/lib/auth-middleware.ts:38` (plain `!==` compare) and `:39-45` (multi-line warning with path, method, address and User-Agent on every failed attempt, no rate limit).
- Scenario: unauthenticated callers can drive log volume and measure a non-constant-time compare. Classic line injection is not possible (Node rejects raw CR/LF in header values and the path is percent-encoded), but other control characters in the User-Agent are logged as is. The same shared key guards these routes and the pages routes, so one leak exposes both.
- Recommended fix: constant-time compare (as in `fork-pages/auth.ts`) and a rate-limited failure log. Upstream code: document only.

### N2 Low (fork): redirects are followed with the key header

- Where: `apps/api/plane/utils/live_pages.py:50` and `:72` (`requests.get` and `requests.post` follow redirects by default and keep custom headers on same-host redirects).
- Scenario: a redirect from the live url (proxy misconfiguration) would carry the shared key header along. Not reachable from user input; the host comes only from the operator-set `LIVE_URL`.
- Recommended fix: `allow_redirects=False` on both calls.

### N3 Info (fork): key rotation needs a coordinated restart

- Where: the API reads `LIVE_SERVER_SECRET_KEY` per call (`apps/api/plane/utils/live_pages.py:40`); live reads it once at start.
- Scenario: rotating the key means restarting both services; in between the API gets 401, so presence is unknown (409) and rebase is 503. This fails closed and is acceptable. Add the restart order and the expected brief write outage to the deploy notes.

Checked, no finding: SSRF (host only from `LIVE_URL`, the only variable path part is a database UUID); log injection in the API (log lines carry page id, exception type and a `json.dumps` summary); presence endpoint auth (same guard and fixed check order as the rebase route, one boolean after the key check).

## Proposed fix tickets

Upstream items are documented only and get no fix ticket.

| Title                                                                                                                       | Severity | Origin   | Blocks deploy |
| --------------------------------------------------------------------------------------------------------------------------- | -------- | -------- | ------------- |
| Bound and offload the rebase conversion in the live service (F1)                                                            | High     | fork     | Yes           |
| Move live calls out of the row lock; add a version check (F3, F4)                                                           | Medium   | fork     | No            |
| Make live the single writer or add a document write lock (F4)                                                               | Medium   | fork     | No            |
| Visibility-scope external id duplicate and `parent` (F5, F6)                                                                | Low      | fork     | No            |
| Reject example and short shared secrets; uniform pre-auth responses (F8, F9)                                                | Low      | fork     | No            |
| Input bounds: `name` length and streamed size cap (F11 fork part)                                                           | Low      | fork     | No            |
| Disable redirects in the live client (N2)                                                                                   | Low      | fork     | No            |
| Deploy notes: key rotation order (N3)                                                                                       | Info     | fork     | No            |
| Documented only: F2 owner role check, F7 archive cascade, F11 sanitiser double parse, F12 `style`, N1 constant-time compare | Low      | upstream | No            |

## Tests run for this review

- `fork/test/cloud-node-tests.sh install build-libs live-test`: 170 passed (live suite, including the `fork-pages` auth, endpoint and rebase tests).
- `fork/test/cloud-api-tests.sh --services apt plane/tests/contract/api/test_pages.py` plus six temporary probe tests (not committed): 200 passed, so all 194 existing pages tests pass and the probes behaved as described in F2, F5, F6, F7 and F11.
- Temporary live probe (not committed) timing `rebase()` for F1.
