<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Bulk update of work items and cycle automation (PLN-129)

For scripts and agents (the Gavel managers, the lead's scripts) and for project admins.

## REST v1: bulk update

`POST /api/v1/workspaces/<slug>/projects/<project_id>/work-items/bulk-update/`

Authentication: the normal `/api/v1` API key (`X-API-Key`). Permission: project member or admin (guests are refused).

```json
{
  "work_item_ids": ["<uuid>", "<uuid>"],
  "state": "<state uuid>",
  "priority": "urgent | high | medium | low | none",
  "labels": ["<label uuid>"],
  "assignees": ["<user uuid>"],
  "cycle": "<cycle uuid> | null"
}
```

- `work_item_ids` is required, 1 to 500 ids of work items of this project. Archived, draft and intake (triage) work
  items count as not found.
- At least one change. Every change is optional:
  - `state`, `priority`: set;
  - `labels`, `assignees`: **added** to what each work item already has (nothing is removed). Assignees must be active
    members (member role and up);
  - `cycle`: moves the work items to that cycle (not archived, not completed); `null` removes them from their cycle.
- **All or nothing.** Every id and value is checked first. Any problem is 400, for example
  `{"work_item_ids": ["Work items not found in this project: [...]"]}` or `{"state": ["State is not a state of this project."]}`,
  and nothing is changed. Unknown body keys are 400.
- **One transaction.** The changes are written together.
- **Answer 200:** `{"updated": [ids], "unchanged": [ids]}`, in request order. `unchanged` lists the work items that
  already had every requested value (no write, no activity).
- **Activity:** one activity entry per changed work item and field, by the caller, as for a single edit (subscribers
  are notified the same way).
- **Live updates:** one live event for the whole batch, so open boards refresh once, not once per work item.

Example: close a sprint (move every work item in "Testing Complete" to "Done"). List the cycle's work items, keep the
ids in "Testing Complete", then:

```sh
curl -sS -X POST "$PLANE/api/v1/workspaces/$WS/projects/$PROJECT/work-items/bulk-update/" \
  -H "X-API-Key: $PLANE_API_KEY" -H "Content-Type: application/json" \
  -d '{"work_item_ids": ["..."], "state": "<Done state id>"}'
```

More than 500 work items: send several calls of at most 500. Each call is its own transaction and its own live event.

## Cycle automation rules

Project settings > Automations > Cycle automation (project admins).

- A rule is: when a cycle **starts** or **completes**, move the cycle's work items that are in one of the source
  states to the target state. Rules of one trigger run in list order, each one seeing the result of the previous one.
- **Presets** (added off): on start, Backlog states to Todo; on completion, Testing Complete to Done (the
  presets are available when the project has those states).
- **When they run:** a cycle has started when its start date has passed and its end date has not; it has completed
  when its end date has passed. Rules run every 5 minutes, and right away when a cycle is created or its dates are
  edited (app or REST v1). Each rule runs **once per cycle**. If a cycle's dates change so that it is no longer
  started or completed, the rule can run again for it later.
- **Turning a rule on does not move anything** in cycles that already started or completed. To apply a rule to the
  current sprint, use **Move work items** on the cycle (cycle menu): pick the source states and the target state, see
  the count, move. Members and admins can use it.
- **Actor:** rule moves appear in the activity as "Cycle automation" (a bot user per workspace) and send no
  notifications. Manual moves and REST v1 calls are by the caller.
- Upstream's transfer of incomplete work items when a cycle completes is unchanged.

## App: selection bulk bar (fork only)

In the list and spreadsheet layouts of a project, cycle, module or project view, selecting work items shows a bar that
sets the state and/or priority of the selection in one call (`POST /api/workspaces/<slug>/projects/<id>/bulk-operation-issues/`,
the payload upstream's web client already sends). Not offered upstream: there the bar is part of the paid edition.
