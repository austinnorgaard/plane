# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

import json
import uuid
from unittest import mock

import pytest

from plane.utils import live_events
from plane.utils.live_events import publish_work_item_event

PROJECT = str(uuid.uuid4())
ACTOR = str(uuid.uuid4())


@pytest.fixture
def redis_mock():
    with mock.patch.object(live_events, "redis_instance") as factory:
        yield factory.return_value


@pytest.fixture
def enabled(monkeypatch):
    monkeypatch.setenv("LIVE_EVENTS_ENABLED", "1")


@pytest.mark.unit
class TestPublishWorkItemEvent:
    def test_publishes_ids_only_payload_to_project_channel(self, enabled, redis_mock):
        a, b = str(uuid.uuid4()), uuid.uuid4()
        assert publish_work_item_event(PROJECT, [a, b], "cycle", "deleted", ACTOR, settle=True) is True
        channel, body = redis_mock.publish.call_args.args
        assert channel == f"plane:live-events:{PROJECT}"
        assert json.loads(body) == {
            "v": 1,
            "project_id": PROJECT,
            "kind": "cycle",
            "verb": "deleted",
            "ids": [a, str(b)],
            "actor_id": ACTOR,
            "settle": True,
        }

    def test_wildcard_ids(self, enabled, redis_mock):
        publish_work_item_event(PROJECT, "*", "issue", "updated", ACTOR)
        assert json.loads(redis_mock.publish.call_args.args[1])["ids"] == "*"
        assert json.loads(redis_mock.publish.call_args.args[1])["settle"] is False

    def test_empty_ids_publishes_nothing(self, enabled, redis_mock):
        assert publish_work_item_event(PROJECT, [], "issue", "updated", ACTOR) is False
        redis_mock.publish.assert_not_called()

    @pytest.mark.parametrize("value", [None, "", "0", "true", "yes", "2"])
    def test_flag_off_publishes_nothing(self, monkeypatch, redis_mock, value):
        if value is None:
            monkeypatch.delenv("LIVE_EVENTS_ENABLED", raising=False)
        else:
            monkeypatch.setenv("LIVE_EVENTS_ENABLED", value)
        with mock.patch.object(live_events, "redis_instance") as factory:
            assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is False
            factory.assert_not_called()

    def test_redis_failure_is_swallowed(self, enabled, redis_mock):
        redis_mock.publish.side_effect = ConnectionError("down")
        assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is False

    def test_redis_connect_failure_is_swallowed(self, enabled):
        with mock.patch.object(live_events, "redis_instance", side_effect=RuntimeError("no url")):
            assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is False

    def test_unserialisable_input_is_swallowed(self, enabled, redis_mock):
        assert publish_work_item_event(PROJECT, 5, "issue", "updated", ACTOR) is False

    def test_failure_log_does_not_contain_connection_details(self, enabled, redis_mock, caplog):
        secret = "redis://:pw-marker@host-marker:6379/0"
        redis_mock.publish.side_effect = ConnectionError(f"Error connecting to {secret}")
        with caplog.at_level("DEBUG"):
            publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        assert "pw-marker" not in caplog.text
        assert "host-marker" not in caplog.text
