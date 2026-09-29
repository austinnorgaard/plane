# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

import json
import time
import uuid
from unittest import mock

import pytest

from plane.utils import live_events
from plane.utils.live_events import publish_work_item_event

PROJECT = str(uuid.uuid4())
ACTOR = str(uuid.uuid4())


@pytest.fixture
def redis_mock():
    with mock.patch.object(live_events, "_publish_client") as factory:
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
        before = time.time()
        payload = json.loads(body)
        ts = payload.pop("ts")
        assert isinstance(ts, float) and abs(ts - before) < 5
        assert payload == {
            "v": 1,
            "project_id": PROJECT,
            "kind": "cycle",
            "verb": "deleted",
            "issue_ids": [a, str(b)],
            "actor_id": ACTOR,
            "settle": True,
        }

    def test_wildcard_ids(self, enabled, redis_mock):
        publish_work_item_event(PROJECT, "*", "issue", "updated", ACTOR)
        assert json.loads(redis_mock.publish.call_args.args[1])["issue_ids"] == "*"
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
        with mock.patch.object(live_events, "_publish_client") as factory:
            assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is False
            factory.assert_not_called()

    def test_redis_failure_is_swallowed(self, enabled, redis_mock):
        redis_mock.publish.side_effect = ConnectionError("down")
        assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is False

    def test_redis_connect_failure_is_swallowed(self, enabled):
        with mock.patch.object(live_events, "_publish_client", side_effect=RuntimeError("no url")):
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


@pytest.mark.unit
class TestPublishClient:
    def test_client_has_short_timeouts(self, settings):
        settings.REDIS_SSL = False
        settings.REDIS_URL = "redis://localhost:6379/"
        with mock.patch.object(live_events.redis.Redis, "from_url") as from_url:
            live_events._publish_client()
        kwargs = from_url.call_args.kwargs
        assert kwargs["socket_connect_timeout"] == live_events.SOCKET_TIMEOUT_SECONDS
        assert kwargs["socket_timeout"] == live_events.SOCKET_TIMEOUT_SECONDS

    def test_ssl_client_has_short_timeouts(self, settings):
        settings.REDIS_SSL = True
        settings.REDIS_URL = "rediss://:pw-marker@host-marker:6380/0"
        with mock.patch.object(live_events.redis, "Redis") as cls:
            live_events._publish_client()
        kwargs = cls.call_args.kwargs
        assert kwargs["ssl"] is True
        assert kwargs["socket_timeout"] == live_events.SOCKET_TIMEOUT_SECONDS

    def test_client_is_closed_after_publish(self, enabled, redis_mock):
        publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        redis_mock.close.assert_called_once()

    def test_client_is_closed_after_publish_failure(self, enabled, redis_mock):
        redis_mock.publish.side_effect = ConnectionError("down")
        publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        redis_mock.close.assert_called_once()

    def test_close_failure_is_swallowed(self, enabled, redis_mock):
        redis_mock.close.side_effect = RuntimeError("x")
        assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is True
