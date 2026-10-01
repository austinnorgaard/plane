# SPDX-License-Identifier: AGPL-3.0-only

"""The fork pages endpoints appear in the generated OpenAPI schema with their status codes."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

API_ROOT = Path(__file__).resolve().parents[4]
PAGES = "/api/v1/workspaces/{slug}/projects/{project_id}/pages/"
PAGE = PAGES + "{page_id}/"
ARCHIVE = PAGE + "archive/"

EXPECTED = {
    (PAGES, "get"): {"200", "400", "401", "403", "404"},
    (PAGES, "post"): {"201", "400", "401", "403", "404", "409", "413"},
    (PAGE, "get"): {"200", "401", "403", "404"},
    (PAGE, "patch"): {"200", "400", "401", "403", "404", "409", "413", "503"},
    (ARCHIVE, "post"): {"200", "400", "401", "403", "404"},
    (ARCHIVE, "delete"): {"204", "401", "403", "404"},
}


@pytest.fixture(scope="module")
def schema(tmp_path_factory):
    out = tmp_path_factory.mktemp("schema") / "schema.json"
    env = {**os.environ, "ENABLE_DRF_SPECTACULAR": "1"}
    result = subprocess.run(
        [sys.executable, "manage.py", "spectacular", "--format", "openapi-json", "--file", str(out)],
        cwd=API_ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, result.stderr[-2000:]
    return json.loads(out.read_text())


def _resolve(schema, node):
    ref = node.get("$ref")
    if ref:
        return schema["components"]["schemas"][ref.rsplit("/", 1)[1]]
    return node


def _body_schema(schema, response):
    return _resolve(schema, response["content"]["application/json"]["schema"])


@pytest.mark.contract
class TestPagesOpenAPI:
    @pytest.mark.parametrize(("path", "method"), sorted(EXPECTED))
    def test_operation_has_status_codes(self, schema, path, method):
        assert path in schema["paths"]
        operation = schema["paths"][path][method]
        assert set(operation["responses"]) == EXPECTED[(path, method)]
        assert operation["tags"] == ["Pages"]

    def test_operation_ids_are_unique_and_named(self, schema):
        ids = [schema["paths"][path][method]["operationId"] for path, method in EXPECTED]
        assert len(set(ids)) == len(ids)
        assert not any(i.startswith("workspaces_projects_pages") for i in ids)

    def test_request_schemas(self, schema):
        create = schema["paths"][PAGES]["post"]["requestBody"]["content"]["application/json"]["schema"]
        assert {"name", "description_html", "external_id", "external_source", "parent"} <= set(
            _resolve(schema, create)["properties"]
        )
        update = schema["paths"][PAGE]["patch"]["requestBody"]["content"]["application/json"]["schema"]
        assert set(_resolve(schema, update)["properties"]) == {"name", "description_html"}

    def test_response_schemas(self, schema):
        detail = _body_schema(schema, schema["paths"][PAGE]["get"]["responses"]["200"])
        assert {"id", "description_html", "archived_at", "project_id"} <= set(detail["properties"])
        listing = _body_schema(schema, schema["paths"][PAGES]["get"]["responses"]["200"])
        assert "results" in listing["properties"]
        archived = _body_schema(schema, schema["paths"][ARCHIVE]["post"]["responses"]["200"])
        assert "archived_at" in archived["properties"]

    @pytest.mark.parametrize(
        ("path", "method", "code", "component"),
        [
            (PAGES, "get", "400", "PageListErrorAPI"),
            (PAGES, "post", "400", "PageValidationErrorAPI"),
            (PAGES, "post", "409", "PageConflictAPI"),
            (PAGES, "post", "413", "PageTooLargeAPI"),
            (PAGE, "patch", "400", "PageValidationErrorAPI"),
            (PAGE, "patch", "409", "PageConflictAPI"),
            (PAGE, "patch", "413", "PageTooLargeAPI"),
            (PAGE, "patch", "503", "PageErrorAPI"),
            (ARCHIVE, "post", "400", "PageErrorAPI"),
            (PAGES, "post", "201", "PageAPI"),
            (PAGE, "patch", "200", "PageAPI"),
            (ARCHIVE, "post", "200", "PageArchiveResultAPI"),
        ],
    )
    def test_response_component_per_status(self, schema, path, method, code, component):
        ref = schema["paths"][path][method]["responses"][code]["content"]["application/json"]["schema"]["$ref"]
        assert ref.rsplit("/", 1)[1] == component

    def test_error_body_properties(self, schema):
        patch = schema["paths"][PAGE]["patch"]["responses"]
        assert {"error", "id"} == set(_body_schema(schema, patch["409"])["properties"])
        assert {"error", "max_bytes"} == set(_body_schema(schema, patch["413"])["properties"])
        assert {"error"} == set(_body_schema(schema, patch["503"])["properties"])
        listing_400 = schema["paths"][PAGES]["get"]["responses"]["400"]
        assert {"detail"} == set(_body_schema(schema, listing_400)["properties"])

    def test_409_documents_retry_after(self, schema):
        description = schema["paths"][PAGE]["patch"]["responses"]["409"]["description"]
        assert "Retry-After" in description
        assert "3600" in description

    def test_page_access_enum_has_a_stable_name(self, schema):
        assert "PageAccessEnum" in schema["components"]["schemas"]
