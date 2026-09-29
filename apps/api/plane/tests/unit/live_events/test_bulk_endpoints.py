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

from plane.db.models import Issue, Module, Project, ProjectMember, State
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
