<!-- SPDX-License-Identifier: AGPL-3.0-only -->

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
2. **Does a document stay in `instance.documents` until its final `onStoreDocument` resolves on unload? Yes.** The only place a document leaves the map is `unloadDocument` (`Hocuspocus.ts:592-601`, `documents.delete` at `:598`). It is called from `storeDocumentHooks` (`:527-548`) only after `onStoreDocument` has resolved and `afterStoreDocument` has run (`:531-541`), from the last-connection close handler (`:372-378`) only when no store is scheduled, and from the `onLoadDocument` failure path (`:494`), where the document never finished loading and nothing is stored. So there is no window where a store is pending and the document is absent from the map, and no extra pending-store signal is needed. The endpoint therefore checks `documents` and `loadingDocuments` only. A test holds `onStoreDocument` open and asserts `loaded: true` during that window.
3. **`prosemirrorJSONToYXmlFragment` in y-prosemirror ^1.3.7: yes.** Installed version 1.3.7; defined at `src/lib.js:317` and re-exported from `src/y-prosemirror.js:8` (the package entry point).

## Running the tests

`apps/live/tests/fork-pages/` runs with the rest of the live suite (`fork/test/node-tests.sh live-test` after `build-libs`).
