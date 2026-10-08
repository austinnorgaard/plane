# Copyright (c) 2023-present Plane Software, Inc. and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# See the LICENSE file for details.

"""The publisher's payload against the shared fixtures in fork/contracts/live-events.

The same fixture file is read by the hub tests (apps/live/tests/events/payload-contract.test.ts),
so changing the payload on one side fails the other side's suite.
"""

import json
from pathlib import Path
from unittest import mock

import pytest

from plane.bgtasks.issue_activities_task import LIVE_EVENT_KINDS, _publish_live_event
from plane.utils import live_events


def _fixture_file():
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "fork" / "contracts" / "live-events" / "events.json"
        if candidate.is_file():
            return candidate
    return None


_FILE = _fixture_file()
pytestmark = [
    pytest.mark.unit,
    pytest.mark.skipif(_FILE is None, reason="fork/contracts/live-events is not in this checkout (api-only mount)"),
]
CONTRACT = json.loads(_FILE.read_text()) if _FILE else {"valid": [], "invalid": [], "producer_fields": {}}
PRODUCIBLE = [c for c in CONTRACT["valid"] if c["producer"]]
FIELD_TYPES = CONTRACT["producer_fields"]
ALL = "*"


def _type_name(value):
    return {"NoneType": "null"}.get(type(value).__name__, type(value).__name__)


def _produce(payload):
    """The real output of the activity-task publish path for a fixture's inputs."""
    ids = payload.get("issue_ids", ALL)
    requested = None if ids == ALL else {"issues": ids}
    with mock.patch.object(live_events, "_publish_client") as factory, mock.patch.dict(
        "os.environ", {"LIVE_EVENTS_ENABLED": "1"}
    ):
        _publish_live_event(
            f"{payload['kind']}.activity.{payload['verb']}",
            requested,
            None,
            None,
            payload.get("actor_id"),
            payload["project_id"],
            [],
        )
        calls = factory.return_value.publish.call_args_list
    assert len(calls) == 1, "the publisher did not publish exactly one message"
    channel, body = calls[0].args
    assert channel == CONTRACT["channel_prefix"] + payload["project_id"]
    return json.loads(body)


def _assert_types(payload):
    assert set(payload) == set(FIELD_TYPES)
    for field, value in payload.items():
        assert _type_name(value) in FIELD_TYPES[field].split("|"), f"{field}: {_type_name(value)}"


@pytest.mark.parametrize("case", PRODUCIBLE, ids=lambda c: c["name"])
def test_publisher_output_matches_fixture(case):
    fixture = case["payload"]
    produced = _produce(fixture)
    assert set(produced) == set(fixture), "field set differs from the fixture"
    for field, value in fixture.items():
        assert _type_name(produced[field]) == _type_name(value), f"type of {field} differs from the fixture"
    _assert_types(produced)
    assert {k: v for k, v in produced.items() if k != "ts"} == {k: v for k, v in fixture.items() if k != "ts"}


@pytest.mark.parametrize("case", PRODUCIBLE, ids=lambda c: c["name"])
def test_producible_fixture_has_the_publisher_field_types(case):
    _assert_types(case["payload"])


def test_every_kind_has_a_producible_fixture():
    assert set(CONTRACT["kinds"]) == set(LIVE_EVENT_KINDS)
    assert {c["payload"]["kind"] for c in PRODUCIBLE} == set(LIVE_EVENT_KINDS)


def test_every_verb_has_a_producible_fixture():
    assert {c["payload"]["verb"] for c in PRODUCIBLE} == set(CONTRACT["verbs"])


@pytest.mark.parametrize("case", [c for c in CONTRACT["valid"] if not c["producer"]], ids=lambda c: c["name"])
def test_hub_only_fixtures_are_not_what_the_publisher_emits(case):
    """A fixture marked producer=false must really differ from the publisher's output."""
    fixture = case["payload"]
    produced = _produce(fixture)
    comparable = lambda d: {k: (_type_name(v), v) for k, v in d.items() if k != "ts"}  # noqa: E731
    differs = comparable(produced) != comparable(fixture) or _type_name(produced["ts"]) != _type_name(
        fixture.get("ts")
    )
    assert differs, "fixture is producible, mark it producer=true"
