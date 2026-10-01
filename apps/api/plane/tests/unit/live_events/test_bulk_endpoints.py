# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

"""Post-write publishes on the bulk endpoints, and the X-Api-Key call-site shape.

These need the database (run with fork/test/api-tests.sh).
"""

import json
import time
import uuid
from unittest import mock

import pytest
from rest_framework import status

from plane.bgtasks import issue_activities_task as task
from plane.db.models import Issue, IssueActivity, Module, Project, ProjectMember, State
from plane.utils.live_events import extract_issue_ids


@pytest.fixture
def project(db, workspace, create_user):
    project = Project.objects.create(name="Live Project", identifier="LP", workspace=workspace, created_by=create_user)
    ProjectMember.objects.create(project=project, member=create_user, role=20, is_active=True)
    return project


@pytest.fixture
def make_issues(db, workspace, project, create_user):
    def _make(n, group="backlog"):
        state = State.objects.create(
            name=f"S-{group}-{uuid.uuid4().hex[:6]}", project=project, workspace=workspace, group=group
        )
        return [
            Issue.objects.create(
                name=f"Issue {i}", workspace=workspace, project=project, state=state, created_by=create_user
            )
            for i in range(n)
        ]

    return _make


@pytest.fixture
def redis_mock(monkeypatch):
    monkeypatch.setenv("LIVE_EVENTS_ENABLED", "1")
    with mock.patch("plane.utils.live_events._publish_client") as factory:
        yield factory.return_value


def published(redis_mock):
    channel, body = redis_mock.publish.call_args.args
    return channel, json.loads(body)


@pytest.mark.contract
class TestBulkEndpointPublishes:
    def test_bulk_delete_publishes_ids_captured_before_delete(
        self, session_client, workspace, project, make_issues, redis_mock
    ):
        issues = make_issues(3)
        ids = sorted(str(i.id) for i in issues)
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/bulk-delete-issues/"
        response = session_client.delete(url, {"issue_ids": ids}, format="json")
        assert response.status_code == status.HTTP_200_OK
        assert Issue.objects.filter(pk__in=ids).count() == 0
        channel, payload = published(redis_mock)
        assert channel == f"plane:live-events:{project.id}"
        assert (payload["kind"], payload["verb"]) == ("issue", "deleted")
        assert sorted(payload["issue_ids"]) == ids
        assert isinstance(payload["ts"], (int, float)) and abs(payload["ts"] - time.time()) < 60

    def test_bulk_delete_400_publishes_nothing(self, session_client, workspace, project, redis_mock):
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/bulk-delete-issues/"
        assert session_client.delete(url, {"issue_ids": []}, format="json").status_code == 400
        redis_mock.publish.assert_not_called()

    def test_bulk_archive_publishes_after_bulk_update(
        self, session_client, workspace, project, make_issues, redis_mock
    ):
        issues = make_issues(2, group="completed")
        ids = sorted(str(i.id) for i in issues)
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/bulk-archive-issues/"
        with mock.patch("plane.app.views.issue.archive.issue_activity"):
            response = session_client.post(url, {"issue_ids": ids}, format="json")
        assert response.status_code == status.HTTP_200_OK
        assert Issue.objects.filter(pk__in=ids, archived_at__isnull=False).count() == 2
        _, payload = published(redis_mock)
        assert (payload["kind"], payload["verb"]) == ("issue", "updated")
        assert sorted(payload["issue_ids"]) == ids

    def test_bulk_archive_invalid_state_publishes_nothing(
        self, session_client, workspace, project, make_issues, redis_mock
    ):
        ids = [str(i.id) for i in make_issues(1, group="backlog")]
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/bulk-archive-issues/"
        with mock.patch("plane.app.views.issue.archive.issue_activity"):
            assert session_client.post(url, {"issue_ids": ids}, format="json").status_code == 400
        redis_mock.publish.assert_not_called()

    def test_bulk_update_dates_publishes_updated_issues(
        self, session_client, workspace, project, make_issues, redis_mock
    ):
        issues = make_issues(2)
        updates = [{"id": str(i.id), "target_date": "2030-01-01"} for i in issues]
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/issue-dates/"
        with mock.patch("plane.app.views.issue.base.issue_activity"):
            response = session_client.post(url, {"updates": updates}, format="json")
        assert response.status_code == status.HTTP_200_OK
        _, payload = published(redis_mock)
        assert sorted(payload["issue_ids"]) == sorted(str(i.id) for i in issues)

    def test_redis_down_does_not_fail_the_mutation(self, session_client, workspace, project, make_issues, redis_mock):
        redis_mock.publish.side_effect = ConnectionError("down")
        ids = [str(i.id) for i in make_issues(1)]
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/bulk-delete-issues/"
        assert session_client.delete(url, {"issue_ids": ids}, format="json").status_code == 200
        assert Issue.objects.filter(pk__in=ids).count() == 0

    def test_flag_off_publishes_nothing(self, monkeypatch, session_client, workspace, project, make_issues):
        monkeypatch.delenv("LIVE_EVENTS_ENABLED", raising=False)
        ids = [str(i.id) for i in make_issues(1)]
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/bulk-delete-issues/"
        with mock.patch("plane.utils.live_events._publish_client") as factory:
            assert session_client.delete(url, {"issue_ids": ids}, format="json").status_code == 200
            factory.assert_not_called()


@pytest.mark.contract
class TestApiKeyCallSiteShape:
    def test_x_api_key_module_bulk_add_25_ids_reach_the_extractor(
        self, api_key_client, workspace, project, create_user, make_issues
    ):
        issues = make_issues(25)
        ids = sorted(str(i.id) for i in issues)
        module = Module.objects.create(name="M", project=project, workspace=workspace)
        url = f"/api/v1/workspaces/{workspace.slug}/projects/{project.id}/modules/{module.id}/module-issues/"
        with mock.patch("plane.api.views.module.issue_activity") as activity:
            response = api_key_client.post(url, {"issues": ids}, format="json")
        assert response.status_code == status.HTTP_200_OK
        kwargs = activity.delay.call_args.kwargs
        assert kwargs["type"] == "module.activity.created"
        assert kwargs["issue_id"] is None
        result = extract_issue_ids(
            kwargs["type"], kwargs["issue_id"], kwargs["requested_data"], kwargs["current_instance"], []
        )
        assert sorted(result) == ids

    def test_x_api_key_is_required(self, api_client, workspace, project):
        url = f"/api/v1/workspaces/{workspace.slug}/projects/{project.id}/modules/{uuid.uuid4()}/module-issues/"
        with mock.patch("plane.api.views.module.issue_activity") as activity:
            response = api_client.post(url, {"issues": [str(uuid.uuid4())]}, format="json")
        assert response.status_code in (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN)
        activity.delay.assert_not_called()


@pytest.mark.contract
class TestSubIssueReparentPublishes:
    def _post(self, session_client, workspace, project, new_parent, sub_ids):
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/issues/{new_parent.id}/sub-issues/"
        with mock.patch("plane.app.views.issue.sub_issue.issue_activity") as activity:
            response = session_client.post(url, {"sub_issue_ids": sub_ids}, format="json")
        assert response.status_code == status.HTTP_200_OK
        return activity

    def test_reparent_publishes_sub_issue_old_and_new_parent(self, session_client, workspace, project, make_issues):
        old, new, sub = make_issues(3)
        Issue.objects.filter(pk=sub.pk).update(parent=old)
        activity = self._post(session_client, workspace, project, new, [str(sub.id)])
        kwargs = activity.delay.call_args.kwargs
        assert json.loads(kwargs["current_instance"]) == {"parent": str(old.id)}
        ids = extract_issue_ids(
            kwargs["type"], kwargs["issue_id"], kwargs["requested_data"], kwargs["current_instance"], []
        )
        assert sorted(ids) == sorted([str(sub.id), str(old.id), str(new.id)])
        sub.refresh_from_db()
        assert sub.parent_id == new.id

    def test_first_assign_has_no_old_parent(self, session_client, workspace, project, make_issues):
        new, sub = make_issues(2)
        activity = self._post(session_client, workspace, project, new, [str(sub.id)])
        kwargs = activity.delay.call_args.kwargs
        assert json.loads(kwargs["current_instance"]) == {"parent": None}
        ids = extract_issue_ids(
            kwargs["type"], kwargs["issue_id"], kwargs["requested_data"], kwargs["current_instance"], []
        )
        assert sorted(ids) == sorted([str(sub.id), str(new.id)])

    def test_each_sub_issue_keeps_its_own_old_parent(self, session_client, workspace, project, make_issues):
        old_a, old_b, new, sub_a, sub_b = make_issues(5)
        Issue.objects.filter(pk=sub_a.pk).update(parent=old_a)
        Issue.objects.filter(pk=sub_b.pk).update(parent=old_b)
        activity = self._post(session_client, workspace, project, new, [str(sub_a.id), str(sub_b.id)])
        seen = {
            c.kwargs["issue_id"]: json.loads(c.kwargs["current_instance"])["parent"]
            for c in activity.delay.call_args_list
        }
        assert seen == {str(sub_a.id): str(old_a.id), str(sub_b.id): str(old_b.id)}


def run_real_task(kwargs):
    """Run the real issue_activity task body (no mock of the handlers) with only the publish and notifications mocked."""
    with (
        mock.patch.object(task, "publish_work_item_event") as publish,
        mock.patch.object(task, "notifications"),
    ):
        task.issue_activity(**kwargs)
    return publish


@pytest.mark.contract
class TestSubIssueAssignRealTask:
    def _post(self, session_client, workspace, project, new_parent, sub_ids):
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/issues/{new_parent.id}/sub-issues/"
        with mock.patch("plane.app.views.issue.sub_issue.issue_activity") as activity:
            response = session_client.post(url, {"sub_issue_ids": sub_ids}, format="json")
        assert response.status_code == status.HTTP_200_OK
        return activity

    def test_reassign_to_same_parent_publishes_parent_once_and_writes_no_parent_row(
        self, session_client, workspace, project, make_issues
    ):
        parent, sub = make_issues(2)
        Issue.objects.filter(pk=sub.pk).update(parent=parent)
        activity = self._post(session_client, workspace, project, parent, [str(sub.id)])
        kwargs = activity.delay.call_args.kwargs
        assert json.loads(kwargs["current_instance"]) == {"parent": str(parent.id)}
        publish = run_real_task(kwargs)
        publish.assert_called_once()
        assert sorted(publish.call_args.args[1]) == sorted([str(sub.id), str(parent.id)])
        assert IssueActivity.objects.filter(issue=sub, field="parent").count() == 0

    def test_real_task_stores_parent_activity_with_old_and_new_values(
        self, session_client, workspace, project, make_issues
    ):
        old, new, sub = make_issues(3)
        Issue.objects.filter(pk=sub.pk).update(parent=old)
        activity = self._post(session_client, workspace, project, new, [str(sub.id)])
        publish = run_real_task(activity.delay.call_args.kwargs)
        row = IssueActivity.objects.get(issue=sub, field="parent")
        assert row.verb == "updated"
        assert row.old_value == f"{project.identifier}-{old.sequence_id}"
        assert row.new_value == f"{project.identifier}-{new.sequence_id}"
        assert row.old_identifier == old.id
        assert row.new_identifier == new.id
        assert sorted(publish.call_args.args[1]) == sorted([str(sub.id), str(old.id), str(new.id)])


@pytest.mark.contract
class TestSubIssueDeletePublishesParent:
    def _delete(self, session_client, workspace, project, issue):
        url = f"/api/workspaces/{workspace.slug}/projects/{project.id}/issues/{issue.id}/"
        with mock.patch("plane.app.views.issue.base.issue_activity") as activity:
            response = session_client.delete(url)
        assert response.status_code == status.HTTP_204_NO_CONTENT
        return activity

    def test_sub_issue_delete_passes_parent_and_publishes_it(self, session_client, workspace, project, make_issues):
        parent, sub = make_issues(2)
        Issue.objects.filter(pk=sub.pk).update(parent=parent)
        activity = self._delete(session_client, workspace, project, sub)
        kwargs = activity.delay.call_args.kwargs
        assert kwargs["current_instance"] == {"parent": str(parent.id)}
        assert json.loads(kwargs["requested_data"]) == {"issue_id": str(sub.id)}
        publish = run_real_task(kwargs)
        assert (publish.call_args.args[2], publish.call_args.args[3]) == ("issue", "deleted")
        assert sorted(publish.call_args.args[1]) == sorted([str(sub.id), str(parent.id)])
        # The feed text for a delete is unchanged and no parent row is written
        rows = IssueActivity.objects.filter(issue_id=sub.id)
        assert [(r.verb, r.field, r.comment) for r in rows] == [("deleted", "issue", "deleted the issue")]

    def test_top_level_issue_delete_still_sends_empty_instance(self, session_client, workspace, project, make_issues):
        (issue,) = make_issues(1)
        activity = self._delete(session_client, workspace, project, issue)
        kwargs = activity.delay.call_args.kwargs
        assert kwargs["current_instance"] == {}
        publish = run_real_task(kwargs)
        assert publish.call_args.args[1] == [str(issue.id)]
