<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Upstream files patched by the fork

One line per touched upstream file: ticket id and the reason.

- `apps/live/src/controllers/index.ts`: PLN-4, register the new EventsController (one import and one list entry).
- `apps/api/plane/api/urls/__init__.py`: PLN-8, include the project pages routes.
- `apps/api/plane/api/views/__init__.py`: PLN-8, export the project pages endpoints.
- `apps/api/plane/api/serializers/__init__.py`: PLN-8, export the project pages serializers.
- `apps/api/plane/utils/order_queryset.py`: PLN-8, add the page list `order_by` allowlist.
- `apps/api/plane/bgtasks/page_version_task.py`: PLN-8, read `page.description_json` instead of the non-existent `page.description` (unconditional fix, two lines).
- `apps/web/app/(all)/[workspaceSlug]/(projects)/projects/(detail)/[projectId]/layout.tsx` (PLN-5): mounts the `useLiveWorkItems` hook for the project.
- `apps/web/core/store/issue/helpers/base-issues.store.ts` (PLN-5): adds `updateIssueList` to the `IBaseIssuesStore` interface (implementation already existed).
- `apps/live/src/controllers/index.ts` - PLN-9: register `PagesController` (one import, one list entry; the same file other live tickets touch).
- `apps/api/plane/bgtasks/issue_activities_task.py`: PLN-3, publish an ids-only live event from a finally block after each activity.
- `apps/api/plane/app/views/issue/base.py`: PLN-3, publish after bulk delete (ids captured first) and after bulk date update.
- `apps/api/plane/app/views/issue/archive.py`: PLN-3, publish after bulk archive.

New files (not upstream): `apps/live/src/controllers/events.controller.ts`, `apps/live/src/events/{config,origin,auth,hub}.ts`, `apps/live/tests/events/*`; `apps/api/plane/api/{urls,views,serializers}/page.py`, `apps/api/plane/utils/live_pages.py`, `apps/api/plane/utils/live_events.py`, `apps/api/plane/tests/unit/live_events/*`, `apps/api/plane/tests/contract/api/test_pages.py`, `fork/PAGES.md`, `apps/live/src/fork-pages/*`, `apps/live/tests/fork-pages/*`, `fork/tools/*`.

## Drift points (new files that mirror private upstream code)

- `apps/live/src/fork-pages/rebase.ts` - PLN-9: `DOC_EXTENSIONS` and its schema are rebuilt from `CoreEditorExtensionsWithoutProps` + `DocumentEditorExtensionsWithoutProps` (`@plane/editor/lib`) because the stock ones are module-private in `packages/editor/src/core/helpers/yjs-utils.ts`. If upstream changes the extension list there, update this file to match.
