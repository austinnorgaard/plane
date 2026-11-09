<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Upstream files patched by the fork

One line per touched upstream file: ticket id and the reason.

- `apps/live/src/controllers/index.ts`: PLN-4, register the new EventsController; PLN-9, register `PagesController` (one import and one list entry for each).
- `apps/api/plane/api/urls/__init__.py`: PLN-8, include the project pages routes.
- `apps/api/plane/api/views/__init__.py`: PLN-8, export the project pages endpoints.
- `apps/api/plane/api/serializers/__init__.py`: PLN-8, export the project pages serializers.
- `apps/live/vitest.config.ts`, `docker-compose-test.yml`: no longer patched; the fork's tests were removed on 2026-11-08 and these test hooks went with them.
- `apps/api/plane/utils/order_queryset.py`: no longer patched. PLN-8 added `PAGE_ORDER_BY_ALLOWLIST`; upstream v1.4.3 ships the same allowlist (same four fields), so the fork pages API imports upstream's.
- `apps/api/plane/bgtasks/page_version_task.py`: PLN-8, read `page.description_json` instead of the non-existent `page.description` (unconditional fix, two lines).
- `apps/web/app/(all)/[workspaceSlug]/(projects)/projects/(detail)/[projectId]/layout.tsx` (PLN-5): mounts the `useLiveWorkItems` hook for the project.
- `apps/web/core/store/issue/helpers/base-issues.store.ts` (PLN-5): adds `updateIssueList` to the `IBaseIssuesStore` interface (implementation already existed).
- `apps/api/plane/bgtasks/issue_activities_task.py`: PLN-3, publish an ids-only live event from a finally block after each activity.
- `apps/api/plane/app/views/issue/base.py`: PLN-3, publish after bulk delete (ids captured first) and after bulk date update.
- `apps/api/plane/app/views/issue/archive.py`: PLN-3, publish after bulk archive.
- `apps/api/plane/app/views/issue/sub_issue.py`: PLN-28, capture each sub-issue's old parent before the assign update and pass it as `current_instance.parent` (upstream passed the sub-issue id), so the live event covers the old parent; the found-sub-issues iteration PLN-29 added is now upstream's own `scoped_sub_issue_ids` (v1.4.3), and the fork keeps upstream's loop.
- `apps/api/plane/app/views/issue/base.py` (destroy): PLN-29, capture the issue's `parent_id` before the delete and pass it as `current_instance.parent` (`{}` when there is no parent), so the live event covers the parent's sub-issue count.
- `apps/api/plane/db/models/__init__.py`: PLN-106, export `ForkUserSettings` (one import at the end).
- `apps/api/plane/app/urls/user.py`: PLN-106, route `users/me/fork-settings/` (one import, one path).
- `apps/live/src/events/config.ts`, `apps/live/src/events/hub.ts`: PLN-106, user-scoped events on `plane:live-events:user:<user_id>`, sent as `{type: "user_event", kind, verb, version}` to every authenticated socket of that user (fork-owned files, listed here because they changed contract).
- `apps/web/core/lib/live-events/client.ts`: PLN-106, parse `user_event` frames, `subscribeUser()` listeners, resync also emitted to user listeners.
- `apps/web/core/store/issue/project/filter.store.ts`: PLN-106, `forkBoard` (ForkGlobalBoard): fetchFilters resolves the board through it; display filter, display property and rich filter writes go to the global template instead of the project row while it is on.
- `apps/web/core/components/issues/filters.tsx`: PLN-106, global board indicator at the top of the project board's display menu.
- `apps/web/core/components/settings/profile/content/pages/preferences/root.tsx`: PLN-106, "Boards" section with the fork board preferences.
- `apps/web/app/(all)/[workspaceSlug]/(projects)/projects/(detail)/[projectId]/layout.tsx` (PLN-106): also mounts `useLiveUserSettings`.
- `packages/i18n/src/locales/en/settings.json`: PLN-106, new `account_settings.preferences.*` board keys (en only; other locales fall back).
- `apps/web/core/components/issues/issue-layouts/kanban/base-kanban-root.tsx`, `.../list/base-list-root.tsx`: PLN-107, the collapse state comes from `useAutoCollapseGroups` (stored state passed through when the setting is off). Also renames the shadowing `projectId` parameter of `canEditProperties` and adds `issues` to the `fetchMoreIssues` deps, upstream lint warnings that the pre-commit `--deny-warnings` hook rejects (no behaviour change).
- `apps/web/core/components/issues/issue-layouts/kanban/default.tsx`: PLN-107, collapsed column header wrapped in `CollapsedColumnDropTarget` (a pass-through unless auto-collapse is on and the column is collapsed).
- `apps/web/core/components/issues/issue-layouts/filters/header/display-filters/display-filters-selection.tsx`: PLN-107, the auto-collapse option under the extra options of grouped layouts.
- `.github/workflows/build-branch.yml` (job `branch_build_setup`; every other job needs it), `.github/workflows/codeql.yml` (job `analyze`), `.github/workflows/react-doctor.yml` (job `react-doctor`): PLN-109, `if: github.repository == 'makeplane/plane'` in a marked fork block. The first two run on pushes to `preview`/`canary`/`master`, which the fork syncs from upstream (build-branch would fail without upstream's registry secrets). react-doctor runs on every pull request to any branch, so it ran on the fork's PRs. The other upstream workflows trigger only on PRs to `preview`/`master` or by hand, and are unchanged.

New files (not upstream): `apps/live/src/controllers/events.controller.ts`, `apps/live/src/events/{config,origin,auth,hub}.ts`; `apps/api/plane/api/{urls,views,serializers}/page.py`, `apps/api/plane/utils/live_pages.py`, `apps/api/plane/utils/live_events.py`, `fork/PAGES.md`, `apps/live/src/fork-pages/*`, `fork/tools/*`; PLN-106: `apps/api/plane/db/models/fork_user_settings.py`, `apps/api/plane/db/migrations/0123_fork_user_settings.py`, `apps/api/plane/app/views/user/fork_settings.py`, `apps/web/core/fork/board-settings/*` (PLN-107 adds `auto-collapse.ts` and its components there); PLN-109: `.github/workflows/fork-images.yml`, `fork/build/service-paths.sh`, `fork/deploy/update.sh` (and fork-owned changes to `fork/deploy/{docker-compose.override.yaml,rollback.sh,inspect.sh,RUNBOOK.md,README.fork}` and `fork/build/build.sh`).

## Drift points (new files that mirror private upstream code)

- `apps/live/src/fork-pages/rebase.ts` - PLN-9: `DOC_EXTENSIONS` and its schema are rebuilt from `CoreEditorExtensionsWithoutProps` + `DocumentEditorExtensionsWithoutProps` (`@plane/editor/lib`) because the stock ones are module-private in `packages/editor/src/core/helpers/yjs-utils.ts`. If upstream changes the extension list there, update this file to match.
