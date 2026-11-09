# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.
"""Keyset (seek) cursor for the pages list of /api/v1.

The stock cursor is an offset into the ordered list, so a walk across pages skips or repeats rows while
pages change (an edited page moves, and every row behind it shifts by one). A keyset cursor carries the
sort key of the boundary row instead: the next page is "the rows after this key" in the same total order,
whatever was inserted, moved or deleted meanwhile. A row that changes during the walk is seen at its old
place or at its new place (or both when it moves forward past the cursor), never lost from the rows that
did not change.

Cursor format: "k1." + base64url(json {"o": order_by, "d": "next" | "prev", "k": [key values]}). It is
opaque to clients; they pass next_cursor / prev_cursor back unchanged.
"""

# Python imports
import base64
import binascii
import json
import math
import uuid

# Django imports
from django.db.models import Q
from django.utils.dateparse import parse_datetime

# Third party imports
from rest_framework.exceptions import ParseError

CURSOR_PREFIX = "k1."
_DATETIME_FIELDS = {"created_at", "updated_at"}
_INVALID = "Invalid cursor parameter."


def ordering_keys(order_by):
    """The total order of the list as [(field, descending)]: the requested field, then -created_at
    for the fields that tie often, then id in the direction of the requested field."""
    descending = order_by.startswith("-")
    field = order_by.lstrip("-")
    keys = [(field, descending)]
    if field not in _DATETIME_FIELDS:
        keys.append(("created_at", True))
    keys.append(("id", descending))
    return keys


def ordering_expressions(keys, reverse=False):
    return [("-" if descending != reverse else "") + field for field, descending in keys]


def _encode_value(field, value):
    if field in _DATETIME_FIELDS:
        return value.isoformat()
    if field == "id":
        return str(value)
    return value


def _decode_value(field, value):
    if field in _DATETIME_FIELDS:
        parsed = parse_datetime(value) if isinstance(value, str) else None
        if parsed is None:
            raise ValueError(field)
        return parsed
    if field == "id":
        return uuid.UUID(str(value))
    if field == "sort_order":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(field)
        return float(value)
    if not isinstance(value, str):
        raise ValueError(field)
    return value


def encode_cursor(order_by, keys, values, direction):
    payload = {
        "o": order_by,
        "d": direction,
        "k": [_encode_value(field, value) for (field, _), value in zip(keys, values)],
    }
    raw = json.dumps(payload, separators=(",", ":")).encode()
    return CURSOR_PREFIX + base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(raw, order_by, keys):
    """Returns (direction, values). Any malformed cursor, or one made for another order_by, is a 400."""
    if not raw.startswith(CURSOR_PREFIX):
        raise ParseError(detail=_INVALID)
    body = raw[len(CURSOR_PREFIX) :]
    try:
        payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        if not isinstance(payload, dict) or payload.get("d") not in ("next", "prev"):
            raise ValueError("shape")
        values = payload.get("k")
        if not isinstance(values, list) or len(values) != len(keys):
            raise ValueError("keys")
        decoded = [_decode_value(field, value) for (field, _), value in zip(keys, values)]
    except (binascii.Error, UnicodeDecodeError, ValueError, TypeError):
        raise ParseError(detail=_INVALID)
    if payload.get("o") != order_by:
        raise ParseError(detail="Invalid cursor parameter: it was made for another order_by.")
    return payload["d"], decoded


def keyset_filter(keys, values, forward):
    """Rows strictly after (forward) or strictly before the boundary key in the order of `keys`."""
    condition = Q()
    equal = {}
    for (field, descending), value in zip(keys, values):
        greater = descending != forward
        condition |= Q(**equal, **{f"{field}__{'gt' if greater else 'lt'}": value})
        equal[field] = value
    return condition


def _row_values(keys, row):
    return [getattr(row, field) for field, _ in keys]


def paginate_keyset(queryset, order_by, per_page, cursor, on_results):
    """One page of `queryset` in the total order of `order_by`, as the /api/v1 list response body."""
    keys = ordering_keys(order_by)
    forward_order = ordering_expressions(keys)
    backward_order = ordering_expressions(keys, reverse=True)
    direction, values = ("next", None) if not cursor else decode_cursor(cursor, order_by, keys)

    if direction == "next":
        window = queryset.filter(keyset_filter(keys, values, True)) if values else queryset
        rows = list(window.order_by(*forward_order)[: per_page + 1])
        has_next = len(rows) > per_page
        rows = rows[:per_page]
        if values is None:
            has_prev = False
        elif rows:
            has_prev = queryset.filter(keyset_filter(keys, _row_values(keys, rows[0]), False)).exists()
        else:
            # nothing after the boundary: is there anything at or before it?
            has_prev = queryset.exclude(keyset_filter(keys, values, True)).exists()
    else:
        window = queryset.filter(keyset_filter(keys, values, False))
        rows = list(window.order_by(*backward_order)[: per_page + 1])
        has_prev = len(rows) > per_page
        rows = rows[:per_page]
        rows.reverse()
        if rows:
            has_next = queryset.filter(keyset_filter(keys, _row_values(keys, rows[-1]), True)).exists()
        else:
            # nothing before the boundary: is there anything at or after it?
            has_next = queryset.exclude(keyset_filter(keys, values, False)).exists()

    if rows:
        next_cursor = encode_cursor(order_by, keys, _row_values(keys, rows[-1]), "next")
        prev_cursor = encode_cursor(order_by, keys, _row_values(keys, rows[0]), "prev")
    elif values is not None:
        # an empty page: both cursors continue from the boundary itself
        next_cursor = encode_cursor(order_by, keys, values, "next")
        prev_cursor = encode_cursor(order_by, keys, values, "prev")
    else:
        next_cursor = prev_cursor = ""
    total = queryset.count()
    return {
        "grouped_by": None,
        "sub_grouped_by": None,
        "total_count": total,
        "next_cursor": next_cursor,
        "prev_cursor": prev_cursor,
        "next_page_results": has_next,
        "prev_page_results": has_prev,
        "count": len(rows),
        "total_pages": math.ceil(total / per_page) if per_page else 0,
        "total_results": total,
        "extra_stats": None,
        "results": on_results(rows),
    }
