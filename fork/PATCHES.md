<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Upstream files patched by the fork

One line per touched upstream file: ticket id and the reason.

- `apps/live/src/controllers/index.ts` - PLN-9: register `PagesController` (one import, one list entry; the same file other live tickets touch).

## Drift points (new files that mirror private upstream code)

- `apps/live/src/fork-pages/rebase.ts` - PLN-9: `DOC_EXTENSIONS` and its schema are rebuilt from `CoreEditorExtensionsWithoutProps` + `DocumentEditorExtensionsWithoutProps` (`@plane/editor/lib`) because the stock ones are module-private in `packages/editor/src/core/helpers/yjs-utils.ts`. If upstream changes the extension list there, update this file to match.
