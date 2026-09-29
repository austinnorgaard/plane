# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

"""Ids-only live events for work items.

After a mutation is recorded, the affected work item ids are published to a
Redis channel per project so a subscriber can tell connected clients to
refetch. No content is ever published, only ids.

Channel: ``plane:live-events:<project_id>``

Payload (JSON)::

    {"v": 1, "project_id": "<uuid>", "kind": "<entity>", "verb": "<verb>",
     "ids": ["<uuid>", ...] | "*", "actor_id": "<uuid>" | null, "settle": bool}

``ids`` is ``"*"`` when the affected set is unknown or larger than
``MAX_IDS``, meaning "refetch everything in the project". ``settle`` asks the
subscriber to also refetch after a short delay, for deletes whose rows may
still be visible to a read that races the write.

Publishing is gated by ``LIVE_EVENTS_ENABLED == "1"`` and never raises.
"""

# Python imports
import json
import logging
import os
import re
import uuid

# Module imports
from plane.settings.redis import redis_instance

logger = logging.getLogger("plane.worker")

CHANNEL_PREFIX = "plane:live-events:"
MAX_IDS = 500
ALL_IDS = "*"

_UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def live_events_enabled():
    return os.environ.get("LIVE_EVENTS_ENABLED") == "1"


def publish_work_item_event(project_id, issue_ids, kind, verb, actor_id, settle=False):
    """Publish an ids-only event for a project. Never raises."""
    try:
        if not live_events_enabled():
            return False
        if issue_ids != ALL_IDS:
            issue_ids = list(dict.fromkeys(str(i) for i in issue_ids))
            if not issue_ids:
                return False
        payload = {
            "v": 1,
            "project_id": str(project_id),
            "kind": kind,
            "verb": verb,
            "ids": issue_ids,
            "actor_id": str(actor_id) if actor_id else None,
            "settle": bool(settle),
        }
        redis_instance().publish(CHANNEL_PREFIX + str(project_id), json.dumps(payload))
        return True
    except Exception as e:
        # Log the exception type only; connection errors can carry the Redis URL.
        logger.warning("live event publish failed: %s", type(e).__name__)
        return False


def _load(value):
    """Accept a JSON string, a dict or None; return a dict (possibly empty)."""
    if isinstance(value, (str, bytes)):
        try:
            value = json.loads(value)
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}


def _uuid_or_none(value):
    if value is None:
        return None
    try:
        return str(uuid.UUID(str(value)))
    except ValueError:
        return None


def _ids_from_list_or_repr(value):
    """A list of ids, or a string holding ids (for example a QuerySet repr)."""
    if isinstance(value, (list, tuple, set)):
        return [_uuid_or_none(v) for v in value]
    if isinstance(value, str):
        return [m.lower() for m in _UUID_RE.findall(value)]
    return []


def _ids_from_records(value, key):
    """[{key: id}, ...] -> ids."""
    if not isinstance(value, (list, tuple)):
        return []
    return [_uuid_or_none(r.get(key)) for r in value if isinstance(r, dict)]


def _ids_from_created_records(value):
    """A list, or a Django serializers JSON string, of records -> [].fields.issue."""
    if isinstance(value, (str, bytes)):
        try:
            value = json.loads(value)
        except ValueError:
            return []
    if not isinstance(value, (list, tuple)):
        return []
    out = []
    for record in value:
        fields = record.get("fields") if isinstance(record, dict) else None
        if isinstance(fields, dict):
            out.append(_uuid_or_none(fields.get("issue")))
    return out


def extract_issue_ids(type, issue_id, requested_data, current_instance, activities):
    """Return the work item ids an issue_activity call touched, or ``"*"``.

    Union of: (a) issue_id unless it is really a cycle or module id, (b)
    requested_data issues, (c) cycles_list, (d) modules_list, (e)
    updated_cycle_issues / updated_module_issues, (f) created_cycle_issues /
    created_module_issues, (g) the in-memory activity rows.
    """
    try:
        req = _load(requested_data)
        cur = _load(current_instance)
        found = []

        # (a) app cycle destroy passes the cycle pk as issue_id
        candidate = _uuid_or_none(issue_id)
        parent_ids = {str(req.get("cycle_id")), str(req.get("module_id"))}
        if candidate is not None and candidate not in parent_ids:
            found.append(candidate)

        # (b)-(d)
        found += _ids_from_list_or_repr(req.get("issues"))
        found += _ids_from_list_or_repr(req.get("cycles_list"))
        found += _ids_from_list_or_repr(req.get("modules_list"))

        # (e)
        found += _ids_from_records(cur.get("updated_cycle_issues"), "issue_id")
        found += _ids_from_records(cur.get("updated_module_issues"), "issue_id")

        # (f)
        found += _ids_from_created_records(cur.get("created_cycle_issues"))
        found += _ids_from_created_records(cur.get("created_module_issues"))

        # (g)
        found += [_uuid_or_none(getattr(a, "issue_id", None)) for a in (activities or [])]

        ids = list(dict.fromkeys(i for i in found if i))
        if len(ids) > MAX_IDS or (not ids and issue_id is None):
            return ALL_IDS
        return ids
    except Exception as e:
        logger.warning("live event id extraction failed: %s", type(e).__name__)
        return ALL_IDS
