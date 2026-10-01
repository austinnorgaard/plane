<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# issue_activity call-site inventory

`tools/callsites.py` lists every place that enqueues the `issue_activity` celery task
(`.delay`, `.apply_async`, direct calls, and aliased imports). `tools/callsites.v1.4.2.txt`
is the snapshot taken from unmodified upstream v1.4.2 (commit 5f7d92784c): 78 call sites.

Upkeep on each upstream rebase:

    python3 fork/tools/callsites.py --check fork/tools/callsites.v1.4.2.txt --ignore-lines

`--ignore-lines` tolerates line shifts in files the fork patches; without it the check is exact.
The snapshot keeps upstream line numbers; two rows (sub_issue.py PLN-28, issue/base.py destroy PLN-29) were edited by hand to the fork's `current_instance` text.
Any diff means a call site was added, removed or changed: give it a row below and a test, then
regenerate the snapshot (`python3 fork/tools/callsites.py --header "<source ref>" > <snapshot>`).
Tool tests: `python3 fork/tools/test_callsites.py` (or pytest).

Extractor sources (`extract_issue_ids` in `apps/api/plane/utils/live_events.py`):
(a) `issue_id` unless it equals `cycle_id` / `module_id`; (b) `requested_data.issues`;
(c) `cycles_list`; (d) `modules_list`; (e) `updated_cycle_issues` / `updated_module_issues`;
(f) `created_cycle_issues` / `created_module_issues`; (g) in-memory IssueActivity `issue_id`s;
(h) `issue.` types only: `parent` in `requested_data` and `current_instance` (id, UUID object or dict with `id`; includes the sub-issue delete);
(i) `issue_relation` types only: `requested_data.related_issue` (relation delete).

Tests live in `apps/api/plane/tests/unit/live_events/`. Abbreviations: `EX` =
`test_extract_issue_ids.py` (class `TestExtractIssueIds`), `AT` = `test_activity_task.py`
(class `TestIssueActivityLiveEvent`), `BE` = `test_bulk_endpoints.py`.
Paths below are relative to `apps/api/plane/`; line numbers are upstream v1.4.2 (the fork patches shift some in app/views/issue/base.py and archive.py). `GAP` = no test covers the row's distinguishing shape.

## Mapping

| Group | Rows (path:line) | Extractor | Covering test | Status |
|---|---|---|---|---|
| Issue create/update/delete, string id | api/views/intake.py:212,404; api/views/issue.py:499,660,720,807,866; app/views/intake/base.py:280,441; app/views/issue/archive.py:264,288; app/views/issue/base.py:421,687,728; app/views/workspace/draft.py:227; space/views/intake.py:161,229 | (a) | EX `test_single_issue_call_sites`; AT `test_published_prefixes[issue.*]`; EX `test_create_with_parent_and_sub_issue_delete_real_shape`; BE `TestSubIssueDeletePublishesParent` (real destroy shape, real task) | covered; a sub-issue delete carries its parent (`current_instance.parent`, PLN-29) |
| Issue update, UUID object id | app/views/estimate/base.py:210,229; bgtasks/issue_automation_task.py:70,133 | (a) | EX `test_uuid_object_inputs`; AT `test_uuid_object_issue_id_from_automation` | covered |
| Bulk archive / bulk dates (per-issue call, plus direct fork publish in the view) | app/views/issue/archive.py:328; app/views/issue/base.py:1155,1168 | (a); view publishes its own ids | BE `test_bulk_archive_publishes_after_bulk_update`, `test_bulk_update_dates_publishes_updated_issues` (both mock `issue_activity`, so they cover the view publish, not this call's extraction) | covered (extraction via EX `test_single_issue_call_sites`) |
| Sub-issue assign | app/views/issue/sub_issue.py:226 | (a) sub-issue id; (h) new parent from `requested_data.parent` and old parent from `current_instance.parent` (the fork view captures the old parent before the update; upstream put the sub-issue id there) | EX `test_sub_issue_assign_publishes_sub_issue_and_parent`, `test_reparent_publishes_sub_issue_old_and_new_parent`, `test_parent_shapes_uuid_object_dict_and_none`, `test_create_with_parent_and_sub_issue_delete_real_shape`, `test_parent_key_ignored_for_non_issue_prefix`; BE `TestSubIssueReparentPublishes` (view captures the old parent), `TestSubIssueAssignRealTask` (same-parent re-assign publishes the parent once with no parent row; real task stores the parent row's old and new values) | covered for (a) and both parents (h) |
| Comment create/update/delete | api/views/issue.py:1490,1630,1676; app/views/issue/comment.py:85,120,149; space/views/issue.py:274,308,329 | (a) | AT `test_publishes_after_success`, `test_published_prefixes[comment.activity.updated]`, `test_settle_flag[comment.activity.deleted]`; EX `test_single_issue_call_sites` | covered |
| Link create/update/delete | api/views/issue.py:1203,1314,1347; app/views/issue/link.py:53,81,101 | (a) | AT `test_published_prefixes[link.activity.updated]`, `test_settle_flag[link.activity.created]`, `test_settle_flag[link.activity.deleted]` | covered |
| Attachment create/delete | api/views/issue.py:2061,2199; app/views/issue/attachment.py:48,74,158,214 | (a) | AT `test_published_prefixes[attachment.activity.created]`; EX `test_single_issue_call_sites` | covered (no `attachment.activity.deleted` prefix case, same code path) |
| Issue relation create/delete | api/views/issue.py:2549; app/views/issue/relation.py:248,282 | (a); (b) `issues` (create); (i) `related_issue` (delete); (g) | EX `test_relation_create_shape`, `test_relation_delete_shape_without_activity_rows`, `test_related_issue_ignored_for_other_prefixes`; AT `test_published_prefixes[issue_relation.activity.created]` | covered |
| Issue reaction create/delete | app/views/issue/reaction.py:50,73; space/views/issue.py:391,417 | (a) | AT `test_published_prefixes[issue_reaction.activity.deleted]` | covered |
| Comment reaction create/delete, `issue_id=None` | app/views/issue/comment.py:193,221; space/views/issue.py:476,503 | (g) only (handler resolves the comment's issue); wildcard `*` if the handler adds no row | EX `test_comment_reaction_with_activity_row_yields_issue_id`, `test_comment_reaction_without_row_is_wildcard`; AT `test_published_prefixes[comment_reaction.activity.deleted]` | covered |
| Intake activity | api/views/intake.py:425; app/views/intake/base.py:463 | (a) | AT `test_published_prefixes[intake.activity.created]` | covered |
| Cycle add / transfer, `issue_id=None` | api/views/cycle.py:1046; app/views/cycle/issue.py:301; utils/cycle_transfer_issues.py:461; app/views/workspace/draft.py:249 | (c), (e), (f) (draft.py:249 is (f) only, `updated_cycle_issues` is None, `requested_data` is None) | EX `test_app_cycle_add_updated_and_created`, `test_cycle_transfer_updated_records_only`, `test_created_records_as_list`; AT `test_in_memory_activities_feed_the_extractor` | covered (draft.py:249 is covered by its parts, no test with that exact combination) |
| Cycle remove one issue | api/views/cycle.py:1156; app/views/cycle/issue.py:327 | (a), (b); `cycle_id` guard | EX `test_cycle_issue_remove_uses_issue_id_and_issues`; AT `test_settle_flag[cycle.activity.deleted]` | covered |
| Cycle destroy | api/views/cycle.py:640 (issue_id None); app/views/cycle/base.py:483 (issue_id is the cycle pk) | (b); (a) drops the cycle pk | EX `test_api_cycle_destroy_issue_id_none`, `test_app_cycle_destroy_passes_cycle_pk_as_issue_id`, `test_app_cycle_destroy_empty_cycle_yields_nothing_not_wildcard`; AT `test_settle_flag[cycle.activity.deleted]` | covered |
| Module add, bulk, `issue_id=None` | api/views/module.py:764 | (d) (QuerySet repr, truncated to 21 by Django), (e), (f) | EX `test_api_module_bulk_add_25_ids`, `test_modules_list_as_python_list`, `test_api_module_bulk_add_updated_records`; BE `test_x_api_key_module_bulk_add_25_ids_reach_the_extractor` | covered |
| Module add, per issue | app/views/module/issue.py:241,281; app/views/workspace/draft.py:284 | (a); `module_id` guard | EX `test_app_module_add_per_issue`, `test_module_id_passed_as_issue_id_is_dropped`; AT `test_settle_flag[module.activity.created]` | covered (module/issue.py:281 passes the raw request value as issue_id; not separately tested) |
| Module remove one issue | api/views/module.py:929; app/views/module/issue.py:302,333 | (a), (b) | EX `test_cycle_issue_remove_uses_issue_id_and_issues`, `test_module_remove_keyed_on_module_id`; AT `test_settle_flag[module.activity.deleted]` | covered |
| Module destroy | api/views/module.py:562 (issue_id None, `issues` list); app/views/module/base.py:729 (issue_id per issue) | (b); (a) | EX `test_module_destroy_issues_list`, `test_api_cycle_destroy_issue_id_none`, `test_app_module_add_per_issue`; AT `test_settle_flag[module.activity.deleted]` | covered |
| Issue vote create/delete | space/views/issue.py:561,581 | skipped: `issue_vote` is not published | AT `test_skipped_types[issue_vote.activity.created]`, `[issue_vote.activity.deleted]` | skip (issue_vote) |
| Issue draft | none in v1.4.2 (the draft view at app/views/workspace/draft.py enqueues `issue.activity.*`, `cycle.*`, `module.*` types, listed above) | skipped: `issue_draft` is not published | AT `test_skipped_types[issue_draft.activity.*]` | skip (issue_draft); no call site today |

Row count check: 78 snapshot rows. Every row appears in exactly one group above.

## GAP rows

None.

## Accepted limits

- Bulk delete (app/views/issue/base.py bulk delete) publishes only the deleted ids, so the parents of deleted sub-issues are not published and their sub-issue counts stay stale for other viewers until the next refetch. The single sub-issue delete (destroy, PLN-29) is covered.
