<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Project pages API (`/api/v1`)

Ticket PLN-8. The whole surface answers 404 unless the environment variable `PAGES_API_ENABLED` is `1`.
Authentication is the normal `/api/v1` API key; permissions come from `ProjectPagePermission`.

## Routes

All paths are under `/api/v1/workspaces/<slug>/projects/<project_id>/`.

| Method | Path | Purpose |
|---|---|---|
| GET | `pages/` | list (cursor paginated, see "Listing and incremental sync"; `?archived=true` lists archived pages; filters `parent_id`, `external_source`, `external_id`, `updated_after`; `order_by` limited to created_at, updated_at, name, sort_order, otherwise the default `-created_at`) |
| POST | `pages/` | create |
| GET | `pages/<page_id>/` | retrieve (includes `description_html`) |
| PATCH | `pages/<page_id>/` | update `name` and/or `description_html` |
| POST | `pages/<page_id>/archive/` | archive (page and descendants) |
| DELETE | `pages/<page_id>/archive/` | unarchive |

The URL kwarg is `page_id` because `ProjectPagePermission` reads `view.kwargs["page_id"]`.

## Listing and incremental sync

Pagination uses the same cursor style as the other `/api/v1` lists: `per_page` (default and maximum 1000) and `cursor`; the
response carries `next_cursor`, `prev_cursor`, `next_page_results`, `prev_page_results`, `count`, `total_results` and `results`.
Pass the `next_cursor` of one response as `cursor` of the next until `next_page_results` is false. An invalid `cursor` or
`per_page` is 400 `{"detail": ...}`.

- **Stable order.** Every ordering ends with `id`, so rows that tie on the ordering field (equal `updated_at`, equal `name`, ...)
  keep one fixed order and a walk across pages never skips or repeats a row (while the data does not change).
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
2. `GET pages/?updated_after=<cursor_ts>&per_page=100`, upsert every result by `id`.
3. Set `cursor_ts` to the largest `updated_at` in the response and repeat from step 2 **without** a cursor, until a response
   returns only rows you already hold (the boundary rows repeat because the filter is inclusive) and `next_page_results` is false.
4. If one response is full of rows that all share the same `updated_at` and `next_page_results` is true, more than a page of
   rows tie on that instant: follow `next_cursor` (same `updated_after`) until the timestamp advances, then go back to step 3.

Why not just follow `next_cursor` for the whole walk: the cursor is an offset into the ordered list. A page you already
fetched and then edit moves to the end of the list, which shifts the rows behind it up by one, so the first row of the next
page can be skipped. Restarting from the newest `updated_at` (step 3) makes each request independent of any offset, so
nothing is skipped; only the tie case in step 4 relies on the offset, and only matters if a page is edited at that moment.

## MCP client contract (open item)

The paths and fields the MCP page tool sends for project-scoped list, retrieve, create, update and archive could not be read from
the build environment (the MCP server source was not reachable). The routes above follow the ticket. If the tool turns out to
use different paths, add aliases here and in `api/urls/page.py`. This is confirmed again by the live-update QA ticket.

## Semantics

- Create: pages start with a NULL binary document and `description_json = {}`; the live service builds the document from
  `description_html` the first time the page is opened. A duplicate `(external_source, external_id)` pair in the project answers
  409 with `{"error": "Page with the same external id and external source already exists", "id": <existing page id>}`; the check runs under a transaction-scoped advisory lock.
  A project with pages disabled (`page_view` false) answers 400; an archived or unknown project answers 404.
  The optional `parent` must be an active page of the same project.
- Update accepts only `name` and `description_html` and **replaces the whole body**; any other key, or an empty body, is 400.
  Locked or archived pages are 400. `description_html` is sanitized; an empty value is stored as `<p></p>`.
- Update never merges into an open document. If the page is loaded in the live service, or its state cannot be determined
  (no live URL, timeout, bad answer), the answer is 409 `{"error": "page is open in an editor; retry later"}` with a `Retry-After: <seconds>` header and nothing is written.
  The header value is set by `PAGES_API_RETRY_AFTER_SECONDS` (default 60 seconds, min 1, max 3600); agents should wait at least that long before retrying.
  - Page without a stored binary: presence is checked, then html/name are written directly and the binary stays NULL.
  - Page with a stored binary: the change is always rebased onto the binary through the live service (a name-only change too,
    because the title lives in the binary), the result is validated, and presence is checked **after** the rebase; the binary,
    html, json and name are then saved together. Live failure or an invalid rebase result is 503
    `{"error": "live service unavailable, page not updated"}`.
- Request bodies larger than `FILE_SIZE_LIMIT` (5 MB by default) are 413.
- After commit: `page_transaction` and `track_page_version` are queued, and a best-effort presence re-check logs a warning
  (page id only) if the page was opened during the write.
- Archive and unarchive: the page owner or a project admin only. POST by another member is 400; DELETE by another member is 403.
- Create ignores unknown keys; only the documented fields are read. PATCH rejects unknown keys with 400.

## Deploy rules

- `PAGES_API_ENABLED=1` is set on the api and live containers only.
- `LIVE_BASE_URL` is set on the api container ONLY, never on the worker or beat-worker. Reason: `apps/api/plane/bgtasks/copy_s3_object.py` (around lines 73-78) returns early while `LIVE_BASE_URL` is unset; with it set, page duplicate would start calling the live service's convert-document path from the worker.
- `LIVE_BASE_URL` must be a direct internal URL of the live container (for example `http://live:3000`), not the public proxy URL, because the live pages endpoints answer 403 to any request carrying `X-Forwarded-For` or `X-Forwarded-Host` (`apps/live/src/fork-pages/auth.ts`), which would make PATCH return 409 (no stored binary) or 503 (stored binary).
- `LIVE_SERVER_SECRET_KEY` must be set (not the shipped placeholder) on api and live; the value is never logged.
- Only one live replica is supported (presence is per process).

## Failure modes

- **F1:** Live down, `LIVE_URL` unset, or presence unanswerable: For a page with NO stored binary, presence is checked first and returns 409 `{"error": "page is open in an editor; retry later"}`. For a page WITH a stored binary, the rebase runs first: live down, `LIVE_URL` unset or a rebase failure returns 503 `{"error": "live service unavailable, page not updated"}`; 409 only when the rebase succeeded but presence is loaded or unknown. Create, list, retrieve and archive still work.
- **F2:** A page opened in a browser between the presence answer and the commit: the editor's next store may overwrite the API change (lost, not duplicated); the window is milliseconds because presence is checked after the rebase; a post-commit presence re-check logs a warning with the page id.
- **F3:** Unload in progress (last tab closing, final store running): the document stays in the documents map until its final store resolves, so presence says loaded and PATCH returns 409; retry later.
- **F4:** Empty stored binary while a browser still has a cached, unsaved document for the page (after a failed first-open write-back): a direct write followed by the next open can duplicate content in that browser; rare, same exposure as stock.
- **F5:** Replace semantics: `description_html` replaces the whole body and `name` replaces the title; offline edits held only in a browser merge into the new state on reconnect.
- **F6:** Schema normalisation: HTML the document schema cannot represent is dropped; the response returns the normalised HTML.
- **F7:** Single live replica only: presence is per process.
- **F8:** A page open in any tab, including a background tab with a connected socket, refuses API PATCH until closed.
- **F9:** Block-level ids are regenerated for replaced content.

## Live service calls

Both send the `live-server-secret-key` header taken from `LIVE_SERVER_SECRET_KEY`. Neither the key nor page content is logged.

- `GET {LIVE_URL}fork/pages/<id>/loaded`, 3 s timeout, answer `{"loaded": true|false}`; anything else counts as unknown.
- `POST {LIVE_URL}fork/pages/rebase`, `Content-Type: application/vnd.plane-fork.rebase+json`, 10 s timeout. Body
  `{"base_binary" (base64), "description_html" (string or null), "name" (string or null)}`; answer `{"description_binary" (base64), "description_html", "description_json"}`.

# Pages support in the live service (PLN-9)

Two internal endpoints under `/fork/pages`, both behind one guard (`apps/live/src/fork-pages/auth.ts`):

| Route                             | Purpose                                                                                                                                                                                                                                                                                           |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /fork/pages/:page_id/loaded` | `200 {loaded}`; true while the page is in `instance.documents` or `instance.loadingDocuments`. Read-only: never creates, loads or stores a document.                                                                                                                                              |
| `POST /fork/pages/rebase`         | Stateless. Applies new `description_html` and/or `name` on top of a stored `base_binary` inside its lineage and returns `{description_binary, description_html, description_json}`. Content type `application/vnd.plane-fork.rebase+json`, body limit 25 MB, `base_binary` at most 10 MB decoded. |

Guard order: `PAGES_API_ENABLED != '1'` -> 404; empty or placeholder secret -> 503; `X-Forwarded-For` or `X-Forwarded-Host` present -> 403; `live-server-secret-key` header compared with `timingSafeEqual` over sha256 digests -> 401 on mismatch (including a wrong-length key).

## Findings from `@hocuspocus/server` 2.15.2

Paths are relative to `node_modules/@hocuspocus/server/src/`.

1. **Map of documents still loading:** `loadingDocuments: Map<string, Promise<Document>>` at `Hocuspocus.ts:75`. It is filled at `Hocuspocus.ts:436` (`createDocument`) and cleared at `:440` / `:442`. Note that `documents` (`Hocuspocus.ts:77`) is also populated early: `loadDocument` runs the `onCreateDocument` hook first (`:453`) and only then does `documents.set` (`:467`), before `onLoadDocument` runs. So `loadingDocuments` is the only signal during the `onCreateDocument` window; afterwards both maps hold the page (`Document.isLoading` is true until `onLoadDocument` finishes, `Document.ts:54`).
2. **Does a document stay in `instance.documents` until its final `onStoreDocument` resolves on unload? Yes.** The only place a document leaves the map is `unloadDocument` (`Hocuspocus.ts:592-601`, `documents.delete` at `:598`). It is called from `storeDocumentHooks` (`:527-548`) only after `onStoreDocument` has resolved and `afterStoreDocument` has run (`:531-541`), from the last-connection close handler (`:375-378`) when no store is scheduled or the document is still loading, and from the `onLoadDocument` failure path (`:494`), where the document never finished loading and nothing is stored. So there is no window where a store is pending and the document is absent from the map, and no extra pending-store signal is needed. The endpoint therefore checks `documents` and `loadingDocuments` only. A test holds `onStoreDocument` open and asserts `loaded: true` during that window.
3. **`prosemirrorJSONToYXmlFragment` in y-prosemirror ^1.3.7: yes.** Installed version 1.3.7; defined at `src/lib.js:317` and re-exported from `src/y-prosemirror.js:8` (the package entry point).

## Running the tests

`apps/live/tests/fork-pages/` runs with the rest of the live suite (`fork/test/node-tests.sh live-test` after `build-libs`).
