<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Project pages API (`/api/v1`)

Ticket PLN-8. The whole surface answers 404 unless the environment variable `PAGES_API_ENABLED` is `1`.
Authentication is the normal `/api/v1` API key; permissions come from `ProjectPagePermission`.

## Routes

All paths are under `/api/v1/workspaces/<slug>/projects/<project_id>/`.

| Method | Path | Purpose |
|---|---|---|
| GET | `pages/` | list (cursor paginated; `?archived=true` lists archived pages; filters `parent_id`, `external_source`, `external_id`; `order_by` limited to created_at, updated_at, name, sort_order, otherwise the default `-created_at`) |
| POST | `pages/` | create |
| GET | `pages/<page_id>/` | retrieve (includes `description_html`) |
| PATCH | `pages/<page_id>/` | update `name` and/or `description_html` |
| POST | `pages/<page_id>/archive/` | archive (page and descendants) |
| DELETE | `pages/<page_id>/archive/` | unarchive |

The URL kwarg is `page_id` because `ProjectPagePermission` reads `view.kwargs["page_id"]`.

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
  (no live URL, timeout, bad answer), the answer is 409 `{"error": "page is open in an editor; retry later"}` and nothing is written.
  - Page without a stored binary: presence is checked, then html/name are written directly and the binary stays NULL.
  - Page with a stored binary: the change is always rebased onto the binary through the live service (a name-only change too,
    because the title lives in the binary), the result is validated, and presence is checked **after** the rebase; the binary,
    html, json and name are then saved together. Live failure or an invalid rebase result is 503
    `{"error": "live service unavailable, page not updated"}`.
- Request bodies larger than `FILE_SIZE_LIMIT` (5 MB by default) are 413.
- After commit: `page_transaction` and `track_page_version` are queued, and a best-effort presence re-check logs a warning
  (page id only) if the page was opened during the write.
- Archive and unarchive: the page owner or a project admin only. POST by another member is 400; DELETE by another member is 403.

## Live service calls (assumed contract)

Both send the `live-server-secret-key` header taken from `LIVE_SERVER_SECRET_KEY`. Neither the key nor page content is logged.

- `GET {LIVE_URL}fork/pages/<id>/loaded`, 3 s timeout, answer `{"loaded": true|false}`; anything else counts as unknown.
- `POST {LIVE_URL}fork/pages/rebase`, `Content-Type: application/vnd.plane-fork.rebase+json`, 10 s timeout. Body
  `{"base_binary" (base64), "description_html" (string or null), "name" (string or null)}`; answer `{"description_binary" (base64), "description_html", "description_json"}`.
