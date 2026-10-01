# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

import json
import os
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

    def test_over_cap_publishes_wildcard(self, enabled, redis_mock):
        ids = [str(uuid.uuid4()) for _ in range(live_events.MAX_IDS + 1)]
        assert publish_work_item_event(PROJECT, ids, "issue", "deleted", ACTOR, settle=True) is True
        payload = json.loads(redis_mock.publish.call_args.args[1])
        assert payload["issue_ids"] == "*"
        assert payload["kind"] == "issue"
        assert payload["verb"] == "deleted"
        assert payload["actor_id"] == ACTOR
        assert payload["settle"] is True
        assert isinstance(payload["ts"], float)

    def test_exactly_cap_publishes_list(self, enabled, redis_mock):
        ids = [str(uuid.uuid4()) for _ in range(live_events.MAX_IDS)]
        publish_work_item_event(PROJECT, ids, "issue", "deleted", ACTOR)
        assert json.loads(redis_mock.publish.call_args.args[1])["issue_ids"] == ids

    def test_duplicates_are_deduped_before_cap(self, enabled, redis_mock):
        ids = [str(uuid.uuid4()) for _ in range(live_events.MAX_IDS)]
        publish_work_item_event(PROJECT, ids + [ids[0]], "issue", "deleted", ACTOR)
        assert json.loads(redis_mock.publish.call_args.args[1])["issue_ids"] == ids

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
            live_events._build_client()
        kwargs = from_url.call_args.kwargs
        assert kwargs["socket_connect_timeout"] == live_events.SOCKET_TIMEOUT_SECONDS
        assert kwargs["socket_timeout"] == live_events.SOCKET_TIMEOUT_SECONDS

    def test_ssl_client_has_short_timeouts(self, settings):
        settings.REDIS_SSL = True
        settings.REDIS_URL = "rediss://:pw-marker@host-marker:6380/0"
        with mock.patch.object(live_events.redis, "Redis") as cls:
            live_events._build_client()
        kwargs = cls.call_args.kwargs
        assert kwargs["ssl"] is True
        assert kwargs["socket_timeout"] == live_events.SOCKET_TIMEOUT_SECONDS

    def test_publish_does_not_close_the_shared_client(self, enabled, redis_mock):
        publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        redis_mock.close.assert_not_called()

    def test_publish_failure_does_not_close_the_shared_client(self, enabled, redis_mock):
        redis_mock.publish.side_effect = ConnectionError("down")
        assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is False
        redis_mock.close.assert_not_called()


@pytest.fixture
def fresh_client(settings, monkeypatch):
    """Reset the module-level client around a test and count constructions."""
    settings.REDIS_SSL = False
    settings.REDIS_URL = "redis://localhost:6379/"
    monkeypatch.setattr(live_events, "_client", None)
    monkeypatch.setattr(live_events, "_client_pid", None)
    with mock.patch.object(live_events.redis.Redis, "from_url") as from_url:
        yield from_url


@pytest.mark.unit
class TestSharedClient:
    def test_n_publishes_reuse_one_client(self, enabled, fresh_client):
        for _ in range(5):
            assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is True
        assert fresh_client.call_count == 1
        assert fresh_client.return_value.publish.call_count == 5

    def test_client_is_created_lazily(self, enabled, fresh_client):
        assert fresh_client.call_count == 0
        publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        assert fresh_client.call_count == 1

    def test_flag_off_never_creates_a_client(self, monkeypatch, fresh_client):
        monkeypatch.delenv("LIVE_EVENTS_ENABLED", raising=False)
        publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        assert fresh_client.call_count == 0

    def test_new_client_after_fork(self, enabled, fresh_client):
        publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        with mock.patch.object(live_events.os, "getpid", return_value=live_events._client_pid + 1):
            publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
            publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        assert fresh_client.call_count == 2

    def test_inherited_client_is_not_closed_after_fork(self, enabled, fresh_client):
        publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        with mock.patch.object(live_events.os, "getpid", return_value=live_events._client_pid + 1):
            publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
        fresh_client.return_value.close.assert_not_called()

    def test_concurrent_first_use_builds_one_client(self, enabled, fresh_client):
        import threading

        def slow_build(*args, **kwargs):
            time.sleep(0.05)
            return mock.MagicMock()

        fresh_client.side_effect = slow_build
        results = []
        threads = [threading.Thread(target=lambda: results.append(live_events._publish_client())) for _ in range(8)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        assert fresh_client.call_count == 1
        assert len({id(r) for r in results}) == 1

    def test_real_fork_resets_lock_and_client(self, enabled, fresh_client):
        parent_client = live_events._publish_client()
        parent_lock = live_events._client_lock
        assert parent_lock.acquire(timeout=1)  # held at fork time, as by another thread
        read_fd, write_fd = os.pipe()
        pid = os.fork()
        if pid == 0:
            code = 1
            try:
                ok = (
                    live_events._client is None
                    and live_events._client_lock is not parent_lock
                    and not live_events._client_lock.locked()
                    and publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is True
                    and live_events._client_pid == os.getpid()
                )
                code = 0 if ok else 1
            finally:
                os.write(write_fd, str(code).encode())
                os._exit(code)
        os.close(write_fd)
        try:
            _, status = os.waitpid(pid, 0)
            child_result = os.read(read_fd, 8)
        finally:
            os.close(read_fd)
            parent_lock.release()
        assert child_result == b"0", "child saw stale state or could not publish"
        assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
        assert live_events._client is parent_client
        assert live_events._client_lock is parent_lock

    def test_failure_does_not_break_later_publishes(self, enabled, fresh_client):
        fresh_client.return_value.publish.side_effect = [ConnectionError("down"), 1]
        assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is False
        assert publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR) is True
        assert fresh_client.call_count == 1

    def test_hung_cache_adds_at_most_the_timeout(self, enabled, settings, monkeypatch):
        """A listener that accepts but never answers: publish returns False within the socket timeout."""
        import socket
        import threading

        monkeypatch.setattr(live_events, "_client", None)
        monkeypatch.setattr(live_events, "_client_pid", None)
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(5)
        try:
            settings.REDIS_SSL = False
            settings.REDIS_URL = f"redis://127.0.0.1:{srv.getsockname()[1]}/"
            result = []
            worker = threading.Thread(
                target=lambda: result.append(
                    publish_work_item_event(PROJECT, [str(uuid.uuid4())], "issue", "updated", ACTOR)
                ),
                daemon=True,
            )
            started = time.monotonic()
            worker.start()
            worker.join(live_events.SOCKET_TIMEOUT_SECONDS + 8)
            elapsed = time.monotonic() - started
        finally:
            srv.close()
        assert result == [False], "publish did not return: no socket timeout"
        assert elapsed < live_events.SOCKET_TIMEOUT_SECONDS + 3
