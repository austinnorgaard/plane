<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Upstream files patched by the fork

One line per touched upstream file: ticket id and the reason.

- `apps/live/src/controllers/index.ts`: PLN-4, register the new EventsController (one import and one list entry).
- `apps/web/app/(all)/[workspaceSlug]/(projects)/projects/(detail)/[projectId]/layout.tsx` (PLN-5): mounts the `useLiveWorkItems` hook for the project.
- `apps/web/core/store/issue/helpers/base-issues.store.ts` (PLN-5): adds `updateIssueList` to the `IBaseIssuesStore` interface (implementation already existed).

New files (not upstream): `apps/live/src/controllers/events.controller.ts`, `apps/live/src/events/{config,origin,auth,hub}.ts`, `apps/live/tests/events/*`.
