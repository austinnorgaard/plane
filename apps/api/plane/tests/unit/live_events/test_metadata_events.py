# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

import json
import uuid
from unittest import mock

import pytest

from plane.utils import live_events
from plane.utils.live_events import publish_metadata_event

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
class TestPublishMetadataEvent:
    @pytest.mark.parametrize("kind", ["state", "label"])
    @pytest.mark.parametrize("verb", ["created", "updated", "deleted"])
    def test_publishes_wildcard_ids_for_project_channel(self, enabled, redis_mock, kind, verb):
        assert publish_metadata_event(PROJECT, kind, verb, ACTOR) is True
        channel, body = redis_mock.publish.call_args.args
        assert channel == f"plane:live-events:{PROJECT}"
        payload = json.loads(body)
        assert payload["kind"] == kind
        assert payload["verb"] == verb
        assert payload["issue_ids"] == "*"
        assert payload["project_id"] == PROJECT
        assert payload["actor_id"] == ACTOR
        assert payload["settle"] is False
        assert set(payload) == {"v", "project_id", "kind", "verb", "issue_ids", "actor_id", "ts", "settle"}

    def test_delete_can_request_settle(self, enabled, redis_mock):
        assert publish_metadata_event(PROJECT, "label", "deleted", ACTOR, settle=True) is True
        payload = json.loads(redis_mock.publish.call_args.args[1])
        assert payload["settle"] is True

    def test_disabled_publishes_nothing(self, monkeypatch, redis_mock):
        monkeypatch.delenv("LIVE_EVENTS_ENABLED", raising=False)
        assert publish_metadata_event(PROJECT, "state", "created", ACTOR) is False
        redis_mock.publish.assert_not_called()

    def test_redis_failure_never_raises(self, enabled):
        with mock.patch.object(live_events, "_publish_client", side_effect=RuntimeError("no url")):
            assert publish_metadata_event(PROJECT, "state", "updated", ACTOR) is False
