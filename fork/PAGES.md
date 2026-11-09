<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Project pages API (`/api/v1`)

Ticket PLN-8. The whole surface answers 404 unless the environment variable `PAGES_API_ENABLED` is `1`.
Authentication is the normal `/api/v1` API key; permissions come from `ProjectPagePermission`.

## Routes

All paths are under `/api/v1/workspaces/<slug>/projects/<project_id>/`.

| Method | Path                       | Purpose                                                                                                                                                                                                                                                                         |
| ------ | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GET    | `pages/`                   | list (cursor paginated, see "Listing and incremental sync"; `?archived=true` lists archived pages; filters `parent_id`, `external_source`, `external_id`, `updated_after`; `order_by` limited to created_at, updated_at, name, sort_order, otherwise the default `-created_at`) |
| POST   | `pages/`                   | create                                                                                                                                                                                                                                                                          |
| GET    | `pages/<page_id>/`         | retrieve (includes `description_html`)                                                                                                                                                                                                                                          |
| PATCH  | `pages/<page_id>/`         | update `name` and/or `description_html`                                                                                                                                                                                                                                         |
| POST   | `pages/<page_id>/archive/` | archive (page and descendants)                                                                                                                                                                                                                                                  |
| DELETE | `pages/<page_id>/archive/` | unarchive                                                                                                                                                                                                                                                                       |

The URL kwarg is `page_id` because `ProjectPagePermission` reads `view.kwargs["page_id"]`.

## Listing and incremental sync

Pagination: `per_page` (default and maximum 1000) and `cursor`; the response carries the same fields as the other `/api/v1`
lists (`next_cursor`, `prev_cursor`, `next_page_results`, `prev_page_results`, `count`, `total_results`, `results`, ...).
Pass the `next_cursor` of one response as `cursor` of the next until `next_page_results` is false (`prev_cursor` walks back
the same way). An invalid `cursor` or `per_page` is 400 `{"detail": ...}`, and so is a cursor made for another `order_by`.

- **Keyset cursor (PLN-104).** The cursor is opaque (`k1.` + base64url json, `apps/api/plane/utils/page_cursor.py`) and
  carries the sort key of the last row of the page, not an offset. The next page is "the rows after that key" in the same
  total order, so a walk never skips or repeats a page that did not change, whatever is created, edited or deleted meanwhile.
  A page edited during the walk moves: it can show up once more later in the walk (upsert by `id`), and a deleted page simply
  stops appearing. An offset cursor of the old form (`<per_page>:<page>:<is_prev>`, from a walk that spans the deploy) is still
  accepted and paged the old way; every response hands out keyset cursors.
- **Total order.** Every ordering is `order_by`, then `-created_at` for `name` and `sort_order` (they tie often), then `id` in
  the direction of `order_by`, so rows that tie on the ordering field keep one fixed order.
- **`updated_after`** (ISO 8601 date-time). Keeps pages whose `updated_at` is **greater than or equal to** the value
  (inclusive). Without `order_by` the list is ordered by `(updated_at, id)` ascending, oldest change first. An explicit
  `order_by` wins. Forms: `2026-03-01T12:00:00Z`, `2026-03-01T12:00:00.123456+00:00` (url-encode `+` as `%2B`, or use `Z`),
  a value without an offset is UTC, a bare date `2026-03-01` is midnight UTC. Anything else, an empty value included, is
  400 `{"detail": "Invalid updated_after parameter. Use an ISO 8601 date-time."}`. It combines with `archived`, `parent_id`
  and the external filters, and permission filtering is unchanged (private pages of other users are never listed).
- **Why inclusive.** A client that resumes from a stored timestamp must not miss a page that shares that exact timestamp with a
  row it already saw. The cost is that the boundary row can come back once more; upsert by `id`.

Recommended agent loop (incremental sync, safe while pages are being edited):

1. Keep `cursor_ts`, the newest `updated_at` already synced (omit `updated_after` on the very first run).
2. `GET pages/?updated_after=<cursor_ts>&per_page=100`, then follow `next_cursor` until `next_page_results` is false, upserting
   every result by `id`.
3. Store the largest `updated_at` seen as the new `cursor_ts` for the next run.

The old workaround (restart from the newest `updated_at` after every page, because the offset cursor skipped a row whenever
an already fetched page was edited) is no longer needed; it still works.

Index (PLN-104, assessed with EXPLAIN ANALYZE on PostgreSQL 18, scratch data with the Django indexes of pages, project_pages
and projects: 150000 pages in one workspace, one project with 50000 pages and 500 with 200): a keyset page of 100 in the
middle of the 50000-page project by `(updated_at, id)` takes about 90 ms without an extra index and about 80 ms with an index
on `pages (updated_at, id)`; the planner then walks that index across every project and filters the rows of other projects.
A 200-page project takes about 1 ms either way (project_pages.project_id index, then a small sort). The index is not
justified, so no migration was added. Revisit only if a single project grows far beyond 50000 pages.

## MCP client contract (open item)

The paths and fields the MCP page tool sends for project-scoped list, retrieve, create, update and archive could not be read from
the build environment (the MCP server source was not reachable). The routes above follow the ticket. If the tool turns out to
use different paths, add aliases here and in `api/urls/page.py`. This is confirmed again by the live-update QA ticket.

## Semantics

- Create: pages start with a NULL binary document and `description_json = {}`; the live service builds the document from
  `description_html` the first time the page is opened. A duplicate `(external_source, external_id)` pair in the project answers
  409 with `{"error": "Page with the same external id and external source already exists", "id": <existing page id>}`; the check runs under a transaction-scoped advisory lock.
  The pair is unique across the whole project, but `id` is only returned when the caller can see that page (PLN-99); for another
  user's private page the 409 carries the error message only.
  A project with pages disabled (`page_view` false) answers 400; an archived or unknown project answers 404.
  The optional `parent` must be a page of the same project that the caller can see and that is not archived; a hidden,
  unknown or archived parent all answer the same 400 `{"parent": ["Parent page does not belong to this project."]}` (PLN-99).
  `name` is at most 255 characters on create and update (400 above).
- Update accepts only `name` and `description_html` and **replaces the whole body**; any other key, or an empty body, is 400.
  Locked or archived pages are 400. `description_html` is sanitized; an empty value is stored as `<p></p>`.
- Update never merges into an open document. If the page is loaded in the live service, or its state cannot be determined
  (no live URL, timeout, bad answer), the answer is 409 `{"error": "page is open in an editor; retry later"}` with a `Retry-After: <seconds>` header and nothing is written.
  The header value is set by `PAGES_API_RETRY_AFTER_SECONDS` (default 60 seconds, min 1, max 3600); agents should wait at least that long before retrying.
  - Page without a stored binary: html/name are written directly and the binary stays NULL.
  - Page with a stored binary: the change is always rebased onto the binary through the live service (a name-only change too,
    because the title lives in the binary) and the result is validated; the binary, html, json and name are then saved
    together. Live failure or an invalid rebase result is 503 `{"error": "live service unavailable, page not updated"}`.
- **Write ordering (PLN-98).** No live call runs inside a transaction or under a row lock:
  1. read the page and remember its version (`updated_at`, a digest of the binary, html, name, locked, archived);
  2. rebase through live when the page has a binary (no transaction, no lock);
  3. take the live **document write lock** for the page (`POST fork/pages/<id>/write-lock`). Live grants it only while the
     page is not loaded, checking and setting in one step, and while it is held every new load of the page waits in the
     `PageWriteLock` extension (`onLoadDocument`, priority 1000, before the Database fetch). Loaded or unknown is the 409
     above; another API write of the same page holding the lock is 409 `{"error": "page is being updated by another request; retry"}`
     with `Retry-After: 1`;
  4. a short transaction: `select_for_update`, the locked/archived guards again, then the **version check**: if the page is no
     longer the version read in step 1, nothing is written and the answer is 409 `{"error": "page changed during the update; retry"}`
     with `Retry-After: 1` (re-read and send again); otherwise save and commit;
  5. release the lock (`DELETE fork/pages/<id>/write-lock`, token in `x-fork-write-lock-token`), after the commit. An editor
     that opened the page meanwhile now loads the committed state. The lock expires on its own after `PAGES_WRITE_LOCK_TTL_MS`
     (live, default 15000, at most 60000) if the API never releases it.
- **Choice: document write lock, not live as the single writer.** Making live the writer would move the page save (and its
  sanitising, versioning and `page_transaction` side effects) out of the API into the live service, a much larger change to
  upstream code paths. The lock keeps the API as the only writer of the row and closes the race between the presence answer
  and the commit (the old failure mode F2 below), because no load can start while the lock is held and loads that started
  earlier make the lock refuse. Recorded in `fork/docs/security/pln-66-pages-review.md` (F3, F4).
- Rolling deploy: an API that finds no lock route (live older than PLN-98, 404) falls back to the old presence check and logs
  a warning; an older API never asks for the lock. Either deploy order works.
- Request bodies larger than `FILE_SIZE_LIMIT` (5 MB by default) are 413, with or without Content-Length: a chunked body is
  measured from the file Django spooled it to, before it is parsed (PLN-99).
- A live 413 is passed on as 413: `{"error": "description_html too large"}` for live's html cap, `{"error": "page document too
large to update through the API"}` when the stored document plus the html exceed live's raw body cap (PLN-99).
- **Write blocking and availability coupling (review F10).** Any member who has a public page open in the editor keeps its
  document loaded, and every API PATCH of that page gets 409 until the last tab closes; this is intended, but a member can stall
  an integration this way. A live outage (down, `LIVE_URL` unset, an unusable `LIVE_SERVER_SECRET_KEY`) stops all page updates
  through this API: 409 for pages without a stored document, 503 for pages with one. Create, list, retrieve and archive do not
  call live and keep working.
- After commit: `page_transaction` and `track_page_version` are queued (the post-commit presence re-check is gone: the write
  lock makes it unnecessary).
- Archive and unarchive: the page owner or a project admin only. POST by another member is 400; DELETE by another member is 403.
- Create ignores unknown keys; only the documented fields are read. PATCH rejects unknown keys with 400.

## Deploy rules

- `PAGES_API_ENABLED=1` is set on the api and live containers only.
- `LIVE_BASE_URL` is set on the api container ONLY, never on the worker or beat-worker. Reason: `apps/api/plane/bgtasks/copy_s3_object.py` (around lines 73-78) returns early while `LIVE_BASE_URL` is unset; with it set, page duplicate would start calling the live service's convert-document path from the worker.
- `LIVE_BASE_URL` must be a direct internal URL of the live container (for example `http://live:3000`), not the public proxy URL, because the live pages endpoints refuse (404 since PLN-99, 403 before) any request carrying `X-Forwarded-For` or `X-Forwarded-Host` (`apps/live/src/fork-pages/auth.ts`), which would make PATCH return 409 (no stored binary) or 503 (stored binary).
- `LIVE_SERVER_SECRET_KEY` must be set (not the shipped placeholder) on api and live; the value is never logged.
- Only one live replica is supported (presence is per process).

## Failure modes

- **F1:** Live down, `LIVE_URL` unset, or presence unanswerable: For a page with NO stored binary, presence is checked first and returns 409 `{"error": "page is open in an editor; retry later"}`. For a page WITH a stored binary, the rebase runs first: live down, `LIVE_URL` unset or a rebase failure returns 503 `{"error": "live service unavailable, page not updated"}`; 409 only when the rebase succeeded but presence is loaded or unknown. Create, list, retrieve and archive still work.
- **F2:** (closed by PLN-98) A page opened in a browser between the presence answer and the commit could overwrite the API change. The write lock now holds such a load until the commit. Remaining window: only if the lock expires (`PAGES_WRITE_LOCK_TTL_MS`) before the commit finishes; the API then logs "live write lock for page ... expired before it was released".
- **F3:** Unload in progress (last tab closing, final store running): the document stays in the documents map until its final store resolves, so presence says loaded and PATCH returns 409; retry later.
- **F4:** Empty stored binary while a browser still has a cached, unsaved document for the page (after a failed first-open write-back): a direct write followed by the next open can duplicate content in that browser; rare, same exposure as stock.
- **F5:** Replace semantics: `description_html` replaces the whole body and `name` replaces the title; offline edits held only in a browser merge into the new state on reconnect.
- **F6:** Schema normalisation: HTML the document schema cannot represent is dropped; the response returns the normalised HTML.
- **F7:** Single live replica only: presence is per process.
- **F8:** A page open in any tab, including a background tab with a connected socket, refuses API PATCH until closed.
- **F9:** Block-level ids are regenerated for replaced content.

## Live service calls

All send the `live-server-secret-key` header taken from `LIVE_SERVER_SECRET_KEY`. Neither the key nor page content is logged.

- `GET {LIVE_URL}fork/pages/<id>/loaded`, 3 s timeout, answer `{"loaded": true|false}`; anything else counts as unknown.
- `POST {LIVE_URL}fork/pages/rebase`, `Content-Type: application/vnd.plane-fork.rebase+json`, 10 s timeout. Body
  `{"base_binary" (base64), "description_html" (string or null), "name" (string or null)}`; answer `{"description_binary" (base64), "description_html", "description_json"}`.
- `POST {LIVE_URL}fork/pages/<id>/write-lock`, 3 s timeout (PLN-98), answer `{"acquired": true, "token", "ttl_ms"}` or
  `{"acquired": false, "reason": "loaded" | "busy"}`; 404 means live has no lock route (fallback), anything else is unknown.
- `DELETE {LIVE_URL}fork/pages/<id>/write-lock` with `x-fork-write-lock-token: <token>`, 3 s timeout: 204 released, 404 not held
  (expired).

# Pages support in the live service (PLN-9)

Internal endpoints under `/fork/pages`, all behind one guard (`apps/live/src/fork-pages/auth.ts`):

| Route                                                                            | Purpose                                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /fork/pages/:page_id/loaded`                                                | `200 {loaded}`; true while the page is in `instance.documents` or `instance.loadingDocuments`. Read-only: never creates, loads or stores a document.                                                                                                                                              |
| `POST /fork/pages/:page_id/write-lock`, `DELETE /fork/pages/:page_id/write-lock` | PLN-98 document write lock (`write-lock.ts`): granted only while the page is not loaded; while held, a new load of the page waits in `onLoadDocument` until release or TTL.                                                                                                                       |
| `POST /fork/pages/rebase`                                                        | Stateless. Applies new `description_html` and/or `name` on top of a stored `base_binary` inside its lineage and returns `{description_binary, description_html, description_json}`. Content type `application/vnd.plane-fork.rebase+json`, body limit 25 MB, `base_binary` at most 10 MB decoded. |

Guard (PLN-99): every refusal answers the same 404 `{"message": "Not Found"}`, so a caller without the key cannot tell the
causes apart (review F9). Refused: `PAGES_API_ENABLED != '1'`; a key that is unset, a known example value
(`change-this-key-on-deployment`, `secret-key`) or shorter than 32 characters (review F8); `X-Forwarded-For` or
`X-Forwarded-Host` present; a `live-server-secret-key` header that does not match (sha256 digests compared with
`timingSafeEqual`, so a wrong-length key neither throws nor leaks its length). The cause is logged internally, at most once
a minute per cause, without the key. At startup live logs a warning when the key is unusable, and when `NODE_OPTIONS` sets
`--max-old-space-size` (it overrides the rebase worker heap limit). The api applies the same key rule: with an unusable
key it makes no live call and treats live as unavailable (logged once). The api calls live with redirects disabled (review N2).

## Findings from `@hocuspocus/server` 2.15.2

Paths are relative to `node_modules/@hocuspocus/server/src/`.

1. **Map of documents still loading:** `loadingDocuments: Map<string, Promise<Document>>` at `Hocuspocus.ts:75`. It is filled at `Hocuspocus.ts:436` (`createDocument`) and cleared at `:440` / `:442`. Note that `documents` (`Hocuspocus.ts:77`) is also populated early: `loadDocument` runs the `onCreateDocument` hook first (`:453`) and only then does `documents.set` (`:467`), before `onLoadDocument` runs. So `loadingDocuments` is the only signal during the `onCreateDocument` window; afterwards both maps hold the page (`Document.isLoading` is true until `onLoadDocument` finishes, `Document.ts:54`).
2. **Does a document stay in `instance.documents` until its final `onStoreDocument` resolves on unload? Yes.** The only place a document leaves the map is `unloadDocument` (`Hocuspocus.ts:592-601`, `documents.delete` at `:598`). It is called from `storeDocumentHooks` (`:527-548`) only after `onStoreDocument` has resolved and `afterStoreDocument` has run (`:531-541`), from the last-connection close handler (`:375-378`) when no store is scheduled or the document is still loading, and from the `onLoadDocument` failure path (`:494`), where the document never finished loading and nothing is stored. So there is no window where a store is pending and the document is absent from the map, and no extra pending-store signal is needed. The endpoint therefore checks `documents` and `loadingDocuments` only. A test holds `onStoreDocument` open and asserts `loaded: true` during that window.
3. **`prosemirrorJSONToYXmlFragment` in y-prosemirror ^1.3.7: yes.** Installed version 1.3.7; defined at `src/lib.js:317` and re-exported from `src/y-prosemirror.js:8` (the package entry point).
