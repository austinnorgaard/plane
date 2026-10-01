# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

import json
import uuid
from types import SimpleNamespace

import pytest

from plane.utils.live_events import extract_issue_ids


def u():
    return str(uuid.uuid4())


def ids(n):
    return [u() for _ in range(n)]


def created_json(issue_ids, key="cycle"):
    """Shape produced by django.core.serializers.serialize('json', ...)."""
    return json.dumps(
        [{"model": "db.cycleissue", "pk": u(), "fields": {"issue": i, key: u(), "project": u()}} for i in issue_ids]
    )


def queryset_repr(issue_ids, limit=21):
    """str() of a values_list QuerySet: Django truncates the repr to 21 items."""
    shown = ", ".join(f"UUID('{i}')" for i in issue_ids[:limit])
    tail = ", '...(remaining elements truncated)...'" if len(issue_ids) > limit else ""
    return f"<QuerySet [{shown}{tail}]>"


def call(issue_id=None, requested_data=None, current_instance=None, activities=None):
    return extract_issue_ids("x.activity.y", issue_id, requested_data, current_instance, activities)


@pytest.mark.unit
class TestExtractIssueIds:
    def test_single_issue_call_sites(self):
        # issue create/update/delete, comment, link, attachment, reaction, relation, intake
        a = u()
        assert call(issue_id=a, requested_data=json.dumps({"name": "x"}), current_instance=None) == [a]

    def test_app_cycle_add_updated_and_created(self):
        a, b, c = ids(3)
        cur = {
            "updated_cycle_issues": [{"old_cycle_id": u(), "new_cycle_id": u(), "issue_id": a}],
            "created_cycle_issues": created_json([b, c]),
        }
        result = call(
            requested_data=json.dumps({"cycles_list": [a, b, c]}),
            current_instance=json.dumps(cur),
        )
        assert sorted(result) == sorted([a, b, c])

    def test_cycle_issue_remove_uses_issue_id_and_issues(self):
        a = u()
        req = {"cycle_id": u(), "issues": [a]}
        assert call(issue_id=a, requested_data=json.dumps(req)) == [a]

    def test_app_cycle_destroy_passes_cycle_pk_as_issue_id(self):
        cycle_pk, a, b = u(), u(), u()
        req = {"cycle_id": cycle_pk, "cycle_name": "c", "issues": [a, b]}
        result = call(issue_id=cycle_pk, requested_data=json.dumps(req))
        assert result == [a, b]
        assert cycle_pk not in result

    def test_app_cycle_destroy_empty_cycle_yields_nothing_not_wildcard(self):
        cycle_pk = u()
        req = {"cycle_id": cycle_pk, "issues": []}
        assert call(issue_id=cycle_pk, requested_data=json.dumps(req)) == []

    def test_api_cycle_destroy_issue_id_none(self):
        cycle_pk, a = u(), u()
        req = {"cycle_id": cycle_pk, "issues": [a]}
        assert call(issue_id=None, requested_data=json.dumps(req)) == [a]

    def test_app_module_add_per_issue(self):
        module_id, a = u(), u()
        assert call(issue_id=a, requested_data=json.dumps({"module_id": module_id})) == [a]

    def test_module_id_passed_as_issue_id_is_dropped(self):
        module_id = u()
        result = call(issue_id=module_id, requested_data=json.dumps({"module_id": module_id}))
        assert result == []

    def test_api_module_bulk_add_25_ids(self):
        all_ids = ids(25)
        # The view sends modules_list as str(QuerySet) (truncated to 21 by Django)
        # and the remaining rows arrive through created_module_issues.
        req = {"modules_list": queryset_repr(all_ids)}
        cur = {"updated_module_issues": [], "created_module_issues": created_json(all_ids, key="module")}
        result = call(requested_data=json.dumps(req), current_instance=json.dumps(cur))
        assert sorted(result) == sorted(all_ids)
        assert len(result) == 25

    def test_modules_list_as_python_list(self):
        a, b = ids(2)
        assert sorted(call(requested_data={"modules_list": [a, b]})) == sorted([a, b])

    def test_api_module_bulk_add_updated_records(self):
        a, b = ids(2)
        cur = {
            "updated_module_issues": [{"old_module_id": u(), "new_module_id": u(), "issue_id": a}],
            "created_module_issues": created_json([b], key="module"),
        }
        assert sorted(call(current_instance=json.dumps(cur))) == sorted([a, b])

    def test_cycle_transfer_updated_records_only(self):
        a, b = ids(2)
        cur = {
            "updated_cycle_issues": [{"issue_id": a}, {"issue_id": b}],
            "created_cycle_issues": [],
        }
        req = {"cycles_list": []}
        assert sorted(call(requested_data=json.dumps(req), current_instance=json.dumps(cur))) == sorted([a, b])

    def test_created_records_as_list(self):
        a = u()
        cur = {"created_cycle_issues": [{"fields": {"issue": a}}]}
        assert call(current_instance=cur) == [a]

    def test_activities_source(self):
        a, b = u(), u()
        acts = [SimpleNamespace(issue_id=a), SimpleNamespace(issue_id=b), SimpleNamespace(issue_id=a)]
        assert call(activities=acts) == [a, b]

    def test_uuid_object_inputs(self):
        # issue_automation_task passes UUID objects for issue_id; dict inputs may hold them too.
        a, b, c = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
        result = call(
            issue_id=a,
            requested_data={"issues": [b], "cycles_list": [c]},
            current_instance={"updated_cycle_issues": [{"issue_id": b}]},
            activities=[SimpleNamespace(issue_id=a)],
        )
        assert result == [str(a), str(b), str(c)]

    def test_union_is_deduplicated(self):
        a = u()
        result = call(
            issue_id=a,
            requested_data={"issues": [a]},
            current_instance={"updated_cycle_issues": [{"issue_id": a}]},
            activities=[SimpleNamespace(issue_id=a)],
        )
        assert result == [a]

    @pytest.mark.parametrize("requested_data", [None, "", "not json", "[]", 5, {}])
    @pytest.mark.parametrize("current_instance", [None, "", "{bad", "[]", 5, {}])
    def test_junk_inputs_never_raise(self, requested_data, current_instance):
        assert call(requested_data=requested_data, current_instance=current_instance) == "*"
        assert call(issue_id=u(), requested_data=requested_data, current_instance=current_instance) != "*"

    def test_invalid_candidates_are_dropped(self):
        a = u()
        result = call(
            requested_data={"issues": [a, "nope", None, 12]}, current_instance={"updated_cycle_issues": ["x"]}
        )
        assert result == [a]

    def test_empty_union_with_no_issue_id_is_wildcard(self):
        assert call() == "*"

    def test_more_than_500_ids_is_wildcard(self):
        assert call(requested_data={"issues": ids(501)}) == "*"

    def test_exactly_500_ids_is_kept(self):
        many = ids(500)
        assert call(requested_data={"issues": many}) == many


def call_type(type, issue_id=None, requested_data=None, current_instance=None, activities=None):
    return extract_issue_ids(type, issue_id, requested_data, current_instance, activities)


@pytest.mark.unit
class TestSubIssueRelationAndModuleShapes:
    def test_sub_issue_assign_publishes_sub_issue_and_parent(self):
        sub, parent = u(), u()
        # app/views/issue/sub_issue.py as upstream sent it (current_instance parent is the sub-issue id); the fork now sends the old parent
        result = call_type(
            "issue.activity.updated",
            issue_id=sub,
            requested_data=json.dumps({"parent": parent}),
            current_instance=json.dumps({"parent": sub}),
        )
        assert result == [sub, parent]

    def test_reparent_publishes_sub_issue_old_and_new_parent(self):
        sub, old, new = u(), u(), u()
        result = call_type(
            "issue.activity.updated",
            issue_id=sub,
            requested_data=json.dumps({"parent": new}),
            current_instance=json.dumps({"parent": old, "name": "x"}),
        )
        assert sorted(result) == sorted([sub, old, new])

    def test_parent_shapes_uuid_object_dict_and_none(self):
        sub, old, new = u(), uuid.uuid4(), uuid.uuid4()
        result = call_type(
            "issue.activity.updated",
            issue_id=sub,
            requested_data={"parent": {"id": str(new)}},
            current_instance={"parent": old},
        )
        assert sorted(result) == sorted([sub, str(old), str(new)])
        assert call_type("issue.activity.updated", issue_id=sub, requested_data={"parent": None}) == [sub]
        assert call_type("issue.activity.updated", issue_id=sub, requested_data={"parent": "junk"}) == [sub]

    def test_create_with_parent_and_sub_issue_delete_real_shape(self):
        sub, parent = u(), u()
        created = call_type("issue.activity.created", issue_id=sub, requested_data={"name": "x", "parent": parent})
        assert created == [sub, parent]
        # Real destroy shape (app/views/issue/base.py): requested_data {"issue_id": pk}, current_instance {}.
        # The parent is not published on delete (known limit, see CALLSITES.md "Accepted limits").
        deleted = call_type(
            "issue.activity.deleted", issue_id=sub, requested_data={"issue_id": sub}, current_instance={}
        )
        assert deleted == [sub]

    def test_parent_key_ignored_for_non_issue_prefix(self):
        a, parent = u(), u()
        for type in ("issue_relation.activity.created", "cycle.activity.created", "issue_comment.activity.created"):
            result = call_type(type, issue_id=a, requested_data={"parent": parent}, current_instance={"parent": parent})
            assert result == [a]

    def test_relation_create_shape(self):
        a, b, c = u(), u(), u()
        req = {"relation_type": "blocking", "issues": [b, c]}
        result = call_type("issue_relation.activity.created", issue_id=a, requested_data=json.dumps(req))
        assert result == [a, b, c]

    def test_relation_delete_shape_without_activity_rows(self):
        a, b = u(), u()
        req = {"relation_type": "blocking", "related_issue": b}
        result = call_type("issue_relation.activity.deleted", issue_id=a, requested_data=json.dumps(req), activities=[])
        assert result == [a, b]

    def test_related_issue_ignored_for_other_prefixes(self):
        a, b = u(), u()
        assert call_type("issue.activity.updated", issue_id=a, requested_data={"related_issue": b}) == [a]

    @pytest.mark.parametrize("type", ["comment_reaction.activity.created", "comment_reaction.activity.deleted"])
    def test_comment_reaction_with_activity_row_yields_issue_id(self, type):
        a = u()
        req = {"reaction": "x", "comment_id": u()}
        rows = [SimpleNamespace(issue_id=a)]
        result = call_type(type, issue_id=None, requested_data=json.dumps(req), activities=rows)
        assert result == [a]

    @pytest.mark.parametrize("type", ["comment_reaction.activity.created", "comment_reaction.activity.deleted"])
    def test_comment_reaction_without_row_is_wildcard(self, type):
        assert call_type(type, issue_id=None, requested_data=json.dumps({"reaction": "x"}), activities=[]) == "*"
        assert call_type(type, issue_id=None, requested_data=None, activities=None) == "*"

    def test_module_remove_keyed_on_module_id(self):
        a, module = u(), u()
        req = {"module_id": module, "issues": [a]}
        result = call_type("module.activity.deleted", issue_id=a, requested_data=json.dumps(req))
        assert result == [a]
        # a module pk passed as issue_id is dropped
        assert call_type("module.activity.deleted", issue_id=module, requested_data=json.dumps(req)) == [a]

    def test_module_destroy_issues_list(self):
        module, a, b = u(), u(), u()
        req = {"module_id": module, "module_name": "m", "issues": [a, b]}
        result = call_type("module.activity.deleted", issue_id=None, requested_data=json.dumps(req))
        assert result == [a, b]
        result = call_type("module.activity.deleted", issue_id=module, requested_data=json.dumps(req))
        assert result == [a, b]
