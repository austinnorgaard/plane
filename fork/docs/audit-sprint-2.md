<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Sprint 2 audit (PLN-88)

Scope: the fork as it stands on `live-updates/v1.4.3` at `111d8f6e1` (2026-11-09), compared with upstream tag `v1.4.3`, with emphasis on the work merged since the v1.4.3 port (#47): PLN-35 to PLN-111. Test coverage is out of scope (the fork's no-tests rule). Doc accuracy is PLN-67 (#75).

## 1. Diff size against PATCHES.md

`git diff v1.4.3 HEAD`: 120 files, +14,610 / -128.

|                         | Files | Lines       |
| ----------------------- | ----- | ----------- |
| Upstream files modified | 48    | +671 / -128 |
| Fork-owned files added  | 72    | +13,939     |

Fork-added lines by area: apps/web 3,796, fork/deploy 2,907, apps/live 2,350, apps/api 2,294, fork/build 951, fork/tools 629, .github/workflows 272, other docs the rest.

The patches to upstream files stay small. The largest ones:

| Upstream file                                                        | Change     | Tickets                                                     |
| -------------------------------------------------------------------- | ---------- | ----------------------------------------------------------- |
| `apps/web/core/store/issue/helpers/base-issues.store.ts`             | +109 / -10 | PLN-5, PLN-110 fix (live refetch, local edits, PATCH queue) |
| `apps/web/core/components/issues/issue-layouts/kanban/swimlanes.tsx` | +62 / -13  | PLN-107, 108, 110                                           |
| `apps/api/plane/bgtasks/issue_activities_task.py`                    | +55 / -2   | PLN-3                                                       |
| `apps/web/core/components/issues/issue-layouts/kanban/default.tsx`   | +55 / -21  | PLN-107, 108, 110                                           |
| `apps/api/plane/api/views/module.py`                                 | +47 / -53  | PLN-36, PLN-44                                              |

These five are the most likely to conflict on the next upstream rebase. `fork/tools/rebase-check.sh` (PLN-46) reports them per tag.

**Finding: PATCHES.md missed 8 of the 48 modified upstream files.** Every PATCHES.md path was compared with the diff (`{a,b}` groups expanded, `...` shortened paths matched by directory and file name). The missing files are:

| File                                             | Change                                                          | From                                    |
| ------------------------------------------------ | --------------------------------------------------------------- | --------------------------------------- |
| `apps/api/plane/app/views/issue/label.py`        | `publish_metadata_event` for label create, update and delete    | PLN-35 (#49)                            |
| `apps/api/plane/app/views/state/base.py`         | the same for states                                             | PLN-35 (#49)                            |
| `apps/api/plane/settings/openapi.py`             | the "Pages" tag and the page enum names in the OpenAPI settings | PLN-8, carried by the v1.4.3 port (#47) |
| `apps/api/plane/utils/openapi/decorators.py`     | the `page_docs` decorator                                       | PLN-8, #47                              |
| `apps/live/src/controllers/health.controller.ts` | `GET /health/stats`, behind the live shared secret              | PLN-34, #47                             |
| `apps/live/src/server.ts`                        | stop the pages rebase workers on shutdown                       | PLN-97, #47                             |
| `apps/live/tsdown.config.ts`                     | the rebase worker entry, `exports: false`                       | PLN-97, #47                             |
| `.gitignore`                                     | one trailing blank line (no effect)                             | #47                                     |

This PR adds the seven meaningful ones to PATCHES.md. The `.gitignore` line is noted here only. Cause: the port (#47) re-applied the patches without re-reading PATCHES.md, and PLN-35 never added its lines. `rebase-check.sh` would not have caught it, since it only checks the files PATCHES.md lists, plus conflicts. Proposed ticket P-1 makes that check permanent.

## 2. Stacked-PR conflict churn (Batch 1 to 3)

Six of the eleven lane A PRs needed a base merge after an earlier PR merged, and the same merge often had to be done twice (by the lead and by the author).

| PR            | Conflicted after          | Files in conflict                                  |
| ------------- | ------------------------- | -------------------------------------------------- |
| #57 (PLN-77)  | #56 squash-merged         | `use-live-work-items.ts`, `PATCHES.md`             |
| #62 (PLN-38)  | #57 and #59 squash-merged | `apply.ts`, `use-live-work-items.ts`, `PATCHES.md` |
| #68 (PLN-37)  | #62                       | `apply.ts`, `PATCHES.md`                           |
| #65 (PLN-44)  | #63                       | `PATCHES.md`                                       |
| #70 (PLN-36)  | #65                       | `PATCHES.md`                                       |
| #74 (PLN-111) | #70                       | `PATCHES.md`                                       |

Causes:

1. **Squash merges of stacked PRs.** A stacked branch still carries the original commits of the PR below it. After that PR is squash-merged, the base has the same change as a different commit, so every dependent conflicts on lines it never changed, typically next to its own additions. Each resolution was mechanical (keep the dependent's additions on top of the base), but it took one round trip per PR, in merge order.
2. **One shared insertion point in PATCHES.md.** PATCHES.md is ordered by area, and every api PR in Batch 3 inserted its line just above the same `app/views/issue/base.py` line, which PLN-93 also edited. Three consecutive PRs conflicted on the same two lines. None of these conflicts was about content.
3. **One hot file.** `apps/web/core/lib/live-events/apply.ts` was edited by eight PRs in one sprint (PLN-78, 77, 76, 38, 37, 36, 111, plus the PLN-110 fix). That is what forced the stacking in the first place.

Recommendations: proposed tickets P-2 (PATCHES.md that cannot conflict) and P-3 (split `apply.ts` by target). Process: stack only when two PRs edit the same hunk; otherwise branch from the base and accept a small rebase. Merge a stack bottom-up without other merges in between.

## 3. REST v1 parity (PLN-111)

The PLN-35 metadata events were added to the app views only. The REST v1 label and state endpoints published nothing. Labels created and assigned through REST v1 then reached the browsers as work items with a label id the label store did not know, which renders as nothing until a hard reload. Austin hit this with the "No Tests" label on 110 tickets. PLN-111 (#74) fixed the REST v1 label and state endpoints and added a defensive refresh. PLN-36 (#70) covered REST v1 cycles and modules from the start.

**The lesson:** in this deployment, REST v1 is the main writer (the Gavel agents use it), but each live-events ticket was written against the app views the browser uses. A scan of `apps/api/plane/api/views/*.py` for write methods that neither enqueue `issue_activity` nor call a `publish_*` function lists these candidates (most of them are not work-item changes and need no event):

- **Needs a decision:** estimates (`estimate.py`: estimate and estimate point create, update, delete). These are work-item metadata like labels: a new estimate point shows blank on cards until a reload. The app estimate views do not publish either. Proposed ticket P-4.
- **To verify:** `IntakeIssueDetailAPIEndpoint.delete` and `IssueAttachmentListCreateAPIEndpoint.post` (REST v1 attachment create). Neither publishes on its own; check whether a later step (asset confirmation, intake cleanup) covers them. Proposed ticket P-5.
- **Probably fine:** `TransferCycleIssueAPIEndpoint.post`, which goes through `utils/cycle_transfer_issues.py`; that file enqueues `issue_activity` per work item.
- **Not work-item events:** assets, members, projects. Pages have their own live path (`live_pages.py`).

Proposed ticket P-1 also adds this REST v1 and app parity scan to `fork/tools`.

## 4. Leftovers and efficiency

- **Duplicated applier wiring.** `use-live-work-items.ts` and `use-live-workspace-view.ts` both build the full `LiveWorkItemsApplier` dependencies, including the same "Work item unavailable" toast with a `TODO` to move its text to i18n. PLN-36 and PLN-111 each had to add the same lines in both. Proposed ticket P-3.
- **Workspace views.** At most 50 joined projects are live (PLN-37), in sidebar order. Users with more projects get live updates for the first 50 only. Proposed ticket P-6.
- **Intake.** The open intake detail pane is not refreshed live; the list is (PLN-76). Proposed ticket P-7.
- **Live event bursts.** Events are published when the Celery worker runs `issue_activity`, so a worker backlog drains in bursts. The hub now merges those per work item (PLN-110 fix). The clients then read the work items in chunks of 50: correct, but not free. The worker's lag is not visible anywhere today. Proposed ticket P-8.
- **Full refresh cost.** A metadata event (`"*"`) now costs each client one list refetch plus states, labels, cycles and modules (PLN-36). This is acceptable at the current rate of definition changes (a few per day).
- **No leftover test files, debug output or stray TODOs** in the fork-added code, apart from the i18n TODO above.

## 5. Proposed follow-up tickets

| Id  | Title                                                    | Area      | Size | Notes                                                                                                                                                                                                    |
| --- | -------------------------------------------------------- | --------- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P-1 | PATCHES.md coverage check in fork/tools                  | ops-docs  | S    | Fail when an upstream file in `git diff <tag> HEAD` has no PATCHES.md line. Add the REST v1 and app publish parity scan from section 3. Run it from `rebase-check.sh` and in CI.                         |
| P-2 | PATCHES.md that does not conflict                        | ops-docs  | S    | One section per ticket appended at the end, or one file per ticket under `fork/patches/` with PATCHES.md generated from them. Ends the PATCHES.md conflicts of section 2.                                |
| P-3 | Share the live applier wiring                            | web       | S    | One builder for the applier dependencies used by both hooks. Move the toast text to i18n. Consider splitting `apply.ts` per target (lists, intake, workspace, metadata).                                 |
| P-4 | Live estimate definitions                                | api + web | M    | `publish_metadata_event` for estimate and estimate point changes (app and REST v1). The web refreshes estimates on full refresh. Extend the PLN-111 unknown-id check to estimate points.                 |
| P-5 | REST v1 intake delete and attachment create: live events | api       | S    | Verify, and publish where missing (section 3).                                                                                                                                                           |
| P-6 | Workspace views beyond 50 projects                       | web       | S    | Subscribe the projects present in the loaded view first, then fill up to the cap. Or have the hub accept a workspace-level subscription.                                                                 |
| P-7 | Live intake detail pane                                  | web       | S    | Refresh the open intake item's detail (activity, comments, status) from intake events.                                                                                                                   |
| P-8 | Worker lag visibility                                    | ops / api | S    | Expose the `issue_activity` queue length or lag (for example in the postdeploy log check or the live stats). That would tell backlog bursts apart from fan-out requests (the PLN-110 overflow question). |
