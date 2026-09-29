# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

"""issue_activity: the finally block publishes only once the project is resolved."""

import json
import uuid
from types import SimpleNamespace
from unittest import mock

import pytest

from plane.bgtasks import issue_activities_task as task

PROJECT = str(uuid.uuid4())
ACTOR = str(uuid.uuid4())
WORKSPACE = uuid.uuid4()


@pytest.fixture
def publish():
    with mock.patch.object(task, "publish_work_item_event") as p:
        yield p


@pytest.fixture
def db_mocks():
    with (
        mock.patch.object(task, "Project") as project,
        mock.patch.object(task, "Issue") as issue,
        mock.patch.object(task, "IssueActivity") as activity,
        mock.patch.object(task, "notifications"),
    ):
        project.objects.get.return_value = SimpleNamespace(workspace_id=WORKSPACE)
        issue.objects.filter.return_value.first.return_value = None
        yield SimpleNamespace(project=project, issue=issue, activity=activity)


def run(type, issue_id=None, requested_data=None, current_instance=None, project_id=PROJECT):
    return task.issue_activity(
        type=type,
        requested_data=requested_data,
        current_instance=current_instance,
        issue_id=issue_id,
        actor_id=ACTOR,
        project_id=project_id,
        epoch=1,
    )


@pytest.mark.unit
class TestIssueActivityLiveEvent:
    def test_publishes_after_success(self, publish, db_mocks):
        a = str(uuid.uuid4())
        with mock.patch.object(task, "create_comment_activity"):
            run("comment.activity.created", issue_id=a)
        publish.assert_called_once_with(PROJECT, [a], "comment", "created", ACTOR, settle=False)

    def test_invalid_project_id_does_not_publish(self, publish, db_mocks):
        run("issue.activity.updated", issue_id=str(uuid.uuid4()), project_id="not-a-uuid")
        publish.assert_not_called()

    def test_project_lookup_failure_does_not_publish(self, publish, db_mocks):
        db_mocks.project.objects.get.side_effect = Exception("missing")
        run("issue.activity.updated", issue_id=str(uuid.uuid4()))
        publish.assert_not_called()

    def test_publishes_when_handler_raises_after_workspace_resolved(self, publish, db_mocks):
        a = str(uuid.uuid4())
        with mock.patch.object(task, "update_issue_activity", side_effect=RuntimeError("boom")):
            assert run("issue.activity.updated", issue_id=a) is None
        publish.assert_called_once()
        assert publish.call_args.args[1] == [a]

    def test_publish_failure_never_propagates(self, publish, db_mocks):
        publish.side_effect = RuntimeError("redis down")
        with mock.patch.object(task, "create_comment_activity"):
            assert run("comment.activity.created", issue_id=str(uuid.uuid4())) is None

    def test_extractor_failure_never_propagates(self, publish, db_mocks):
        with (
            mock.patch.object(task, "create_comment_activity"),
            mock.patch.object(task, "extract_issue_ids", side_effect=RuntimeError("x")),
        ):
            assert run("comment.activity.created", issue_id=str(uuid.uuid4())) is None
        publish.assert_not_called()

    def test_backstop_logs_exception_type(self, publish, db_mocks, caplog):
        publish.side_effect = RuntimeError("redis://:pw-marker@host-marker")
        with mock.patch.object(task, "create_comment_activity"), caplog.at_level("WARNING"):
            run("comment.activity.created", issue_id=str(uuid.uuid4()))
        assert "RuntimeError" in caplog.text
        assert "pw-marker" not in caplog.text

    def test_in_memory_activities_feed_the_extractor(self, publish, db_mocks):
        a, b = str(uuid.uuid4()), str(uuid.uuid4())

        def handler(**kwargs):
            kwargs["issue_activities"].append(SimpleNamespace(issue_id=a))
            kwargs["issue_activities"].append(SimpleNamespace(issue_id=b))

        with mock.patch.object(task, "create_cycle_issue_activity", side_effect=handler):
            run("cycle.activity.created", requested_data=json.dumps({"cycles_list": []}))
        assert publish.call_args.args[1] == [a, b]

    @pytest.mark.parametrize(
        "type,kind,verb",
        [
            ("issue.activity.created", "issue", "created"),
            ("issue.activity.updated", "issue", "updated"),
            ("issue.activity.deleted", "issue", "deleted"),
            ("comment.activity.updated", "comment", "updated"),
            ("cycle.activity.created", "cycle", "created"),
            ("module.activity.created", "module", "created"),
            ("link.activity.updated", "link", "updated"),
            ("attachment.activity.created", "attachment", "created"),
            ("issue_relation.activity.created", "issue_relation", "created"),
            ("issue_reaction.activity.deleted", "issue_reaction", "deleted"),
            ("comment_reaction.activity.deleted", "comment_reaction", "deleted"),
            ("intake.activity.created", "intake", "created"),
        ],
    )
    def test_published_prefixes(self, publish, db_mocks, type, kind, verb):
        with mock.patch.multiple(
            task,
            **{
                n: mock.DEFAULT
                for n in (
                    "create_issue_activity",
                    "update_issue_activity",
                    "delete_issue_activity",
                    "update_comment_activity",
                    "create_cycle_issue_activity",
                    "create_module_issue_activity",
                    "update_link_activity",
                    "create_attachment_activity",
                    "create_issue_relation_activity",
                    "delete_issue_reaction_activity",
                    "delete_comment_reaction_activity",
                    "create_intake_activity",
                )
            },
        ):
            run(type, issue_id=str(uuid.uuid4()))
        assert publish.call_args.args[2:4] == (kind, verb)

    @pytest.mark.parametrize(
        "type",
        [
            "issue_draft.activity.created",
            "issue_draft.activity.updated",
            "issue_draft.activity.deleted",
            "issue_vote.activity.created",
            "issue_vote.activity.deleted",
            "unknown.activity.created",
            "garbage",
        ],
    )
    def test_skipped_types(self, publish, db_mocks, type):
        with mock.patch.multiple(
            task,
            create_draft_issue_activity=mock.DEFAULT,
            update_draft_issue_activity=mock.DEFAULT,
            delete_draft_issue_activity=mock.DEFAULT,
            create_issue_vote_activity=mock.DEFAULT,
            delete_issue_vote_activity=mock.DEFAULT,
        ):
            run(type, issue_id=str(uuid.uuid4()))
        publish.assert_not_called()

    @pytest.mark.parametrize(
        "type,settle",
        [
            ("cycle.activity.deleted", True),
            ("module.activity.deleted", True),
            ("link.activity.deleted", True),
            ("cycle.activity.created", False),
            ("module.activity.created", False),
            ("link.activity.created", False),
            ("issue.activity.deleted", False),
            ("comment.activity.deleted", False),
        ],
    )
    def test_settle_flag(self, publish, db_mocks, type, settle):
        with mock.patch.multiple(
            task,
            delete_cycle_issue_activity=mock.DEFAULT,
            delete_module_issue_activity=mock.DEFAULT,
            delete_link_activity=mock.DEFAULT,
            create_cycle_issue_activity=mock.DEFAULT,
            create_module_issue_activity=mock.DEFAULT,
            create_link_activity=mock.DEFAULT,
            delete_issue_activity=mock.DEFAULT,
            delete_comment_activity=mock.DEFAULT,
        ):
            run(type, issue_id=str(uuid.uuid4()))
        assert publish.call_args.kwargs["settle"] is settle

    def test_uuid_object_issue_id_from_automation(self, publish, db_mocks):
        a = uuid.uuid4()
        with mock.patch.object(task, "update_issue_activity"):
            run("issue.activity.updated", issue_id=a, requested_data=json.dumps({"archived_at": "x"}))
        assert publish.call_args.args[1] == [str(a)]
