# SPDX-License-Identifier: AGPL-3.0-only

import base64
import json
from uuid import uuid4

import pytest

from plane.db.models import Page, Project, ProjectMember, ProjectPage, User, WorkspaceMember
from plane.utils import live_pages

LIVE = "plane.api.views.page.live_pages"
OPEN_MSG = {"error": "page is open in an editor; retry later"}
LIVE_DOWN_MSG = {"error": "live service unavailable, page not updated"}


@pytest.fixture(autouse=True)
def pages_enabled(monkeypatch):
    monkeypatch.setenv("PAGES_API_ENABLED", "1")


@pytest.fixture(autouse=True)
def celery_mocks(mocker):
    return {
        "transaction": mocker.patch("plane.api.views.page.page_transaction.delay"),
        "version": mocker.patch("plane.api.views.page.track_page_version.delay"),
    }


@pytest.fixture
def project(db, workspace, create_user):
    project = Project.objects.create(name="Pages Project", identifier="PP", workspace=workspace, created_by=create_user)
    ProjectMember.objects.create(project=project, member=create_user, role=20, is_active=True)
    return project


def make_user(email):
    return User.objects.create(email=email, first_name="M", last_name="U", username=email.split("@")[0])


def join(project, user, role):
    ProjectMember.objects.create(project=project, member=user, role=role, is_active=True)


def make_page(project, owner, **kwargs):
    kwargs.setdefault("name", "A page")
    kwargs.setdefault("description_html", "<p>hello</p>")
    page = Page.objects.create(workspace=project.workspace, owned_by=owner, **kwargs)
    ProjectPage.objects.create(page=page, project=project, workspace=project.workspace)
    return page


def client_for(user, api_client):
    api_client.force_authenticate(user=user)
    return api_client


def base(project):
    return f"/api/v1/workspaces/{project.workspace.slug}/projects/{project.id}/pages/"


def detail(project, page):
    return f"{base(project)}{page.id}/"


def archive_url(project, page):
    return f"{base(project)}{page.id}/archive/"


def binary_page(project, owner, **kwargs):
    return make_page(project, owner, description_binary=b"\x01\x02\x03", **kwargs)


def rebase_answer(html="<p>new</p>"):
    return {
        "description_binary": base64.b64encode(b"\x09\x08\x07\x06\x05").decode(),
        "description_html": html,
        "description_json": {"type": "doc"},
    }


@pytest.mark.contract
class TestFeatureFlagAndAuth:
    def test_disabled_returns_404(self, monkeypatch, session_client, project):
        monkeypatch.setenv("PAGES_API_ENABLED", "0")
        assert session_client.get(base(project)).status_code == 404

    def test_flag_unset_returns_404(self, monkeypatch, session_client, project):
        monkeypatch.delenv("PAGES_API_ENABLED")
        assert session_client.post(base(project), {"name": "x"}, format="json").status_code == 404

    def test_anonymous_denied(self, api_client, project):
        assert api_client.get(base(project)).status_code in (401, 403)

    def test_non_member_denied(self, api_client, project):
        outsider = make_user("out@plane.so")
        assert client_for(outsider, api_client).get(base(project)).status_code == 403


@pytest.mark.contract
class TestListAndRetrieve:
    def test_list_excludes_archived_and_other_projects(self, session_client, project, create_user):
        live = make_page(project, create_user, name="live")
        make_page(project, create_user, name="gone", archived_at="2026-01-01")
        other = Project.objects.create(name="Other", identifier="OT", workspace=project.workspace)
        make_page(other, create_user, name="elsewhere")
        response = session_client.get(base(project))
        assert response.status_code == 200
        assert [r["id"] for r in response.data["results"]] == [str(live.id)]
        assert "description_html" not in response.data["results"][0]

    def test_list_archived(self, session_client, project, create_user):
        gone = make_page(project, create_user, archived_at="2026-01-01")
        response = session_client.get(base(project) + "?archived=true")
        assert [r["id"] for r in response.data["results"]] == [str(gone.id)]

    def test_list_hides_private_pages_of_others(self, api_client, project, create_user):
        member = make_user("m@plane.so")
        join(project, member, 15)
        make_page(project, create_user, name="secret", access=Page.PRIVATE_ACCESS)
        mine = make_page(project, member, name="mine", access=Page.PRIVATE_ACCESS)
        response = client_for(member, api_client).get(base(project))
        assert [r["id"] for r in response.data["results"]] == [str(mine.id)]

    def test_list_in_archived_project_is_empty(self, session_client, project, create_user):
        make_page(project, create_user)
        project.archived_at = "2026-01-01T00:00:00Z"
        project.save()
        assert session_client.get(base(project)).data["results"] == []

    def test_retrieve(self, session_client, project, create_user):
        page = make_page(project, create_user)
        response = session_client.get(detail(project, page))
        assert response.status_code == 200
        assert response.data["description_html"] == "<p>hello</p>"
        assert response.data["project_id"] == str(project.id)

    def test_retrieve_private_of_other_denied(self, api_client, project, create_user):
        member = make_user("m@plane.so")
        join(project, member, 15)
        page = make_page(project, create_user, access=Page.PRIVATE_ACCESS)
        assert client_for(member, api_client).get(detail(project, page)).status_code == 403

    def test_retrieve_page_of_other_project_denied(self, session_client, project, create_user):
        other = Project.objects.create(name="Other", identifier="OT", workspace=project.workspace)
        ProjectMember.objects.create(project=other, member=create_user, role=20, is_active=True)
        page = make_page(other, create_user)
        assert session_client.get(detail(project, page)).status_code == 403

    def test_retrieve_unknown_page(self, session_client, project):
        assert session_client.get(f"{base(project)}{uuid4()}/").status_code == 403


@pytest.mark.contract
class TestCreate:
    def test_create_stores_null_binary_and_empty_json(
        self, session_client, project, celery_mocks, mocker, django_capture_on_commit_callbacks
    ):
        live = mocker.patch(LIVE)
        with django_capture_on_commit_callbacks(execute=True):
            response = session_client.post(
                base(project), {"name": "New", "description_html": "<p>x</p>"}, format="json"
            )
        assert response.status_code == 201
        page = Page.objects.get(pk=response.data["id"])
        assert page.description_binary is None
        assert page.description_json == {}
        assert page.owned_by_id is not None
        assert ProjectPage.objects.filter(page=page, project=project).exists()
        celery_mocks["transaction"].assert_called_once_with(
            new_description_html="<p>x</p>", old_description_html=None, page_id=page.id
        )
        live.is_page_loaded.assert_not_called()
        live.rebase_page.assert_not_called()

    def test_create_sanitizes_html(self, session_client, project):
        response = session_client.post(
            base(project), {"name": "n", "description_html": "<p>ok</p><script>alert(1)</script>"}, format="json"
        )
        assert response.status_code == 201
        assert "script" not in Page.objects.get(pk=response.data["id"]).description_html

    @pytest.mark.parametrize("body", [{"name": "n"}, {"name": "n", "description_html": ""}])
    def test_empty_html_becomes_empty_paragraph(self, session_client, project, body):
        response = session_client.post(base(project), body, format="json")
        assert response.status_code == 201
        assert Page.objects.get(pk=response.data["id"]).description_html == "<p></p>"

    def test_duplicate_external_pair_conflicts_with_id(self, session_client, project):
        body = {"name": "n", "external_id": "e1", "external_source": "sync"}
        first = session_client.post(base(project), body, format="json")
        second = session_client.post(base(project), body, format="json")
        assert first.status_code == 201
        assert second.status_code == 409
        assert second.data == {
            "error": "Page with the same external id and external source already exists",
            "id": first.data["id"],
        }
        assert Page.objects.filter(external_id="e1").count() == 1

    def test_same_external_id_other_source_is_fine(self, session_client, project):
        session_client.post(base(project), {"external_id": "e1", "external_source": "a"}, format="json")
        assert (
            session_client.post(base(project), {"external_id": "e1", "external_source": "b"}, format="json").status_code
            == 201
        )

    def test_advisory_lock_taken_before_duplicate_check(self, session_client, project):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        with CaptureQueriesContext(connection) as queries:
            session_client.post(base(project), {"external_id": "e", "external_source": "s"}, format="json")
        sql = [q["sql"] for q in queries.captured_queries]
        lock = next(i for i, q in enumerate(sql) if "pg_advisory_xact_lock" in q)
        lookup = next(i for i, q in enumerate(sql) if 'FROM "pages"' in q and "external_id" in q)
        assert lock < lookup

    def test_no_lock_without_external_pair(self, session_client, project):
        from django.db import connection
        from django.test.utils import CaptureQueriesContext

        with CaptureQueriesContext(connection) as queries:
            session_client.post(base(project), {"name": "n"}, format="json")
        assert not any("pg_advisory_xact_lock" in q["sql"] for q in queries.captured_queries)

    def test_page_view_disabled_is_400(self, session_client, project):
        project.page_view = False
        project.save()
        assert session_client.post(base(project), {"name": "n"}, format="json").status_code == 400

    def test_archived_project_is_404(self, session_client, project):
        project.archived_at = "2026-01-01T00:00:00Z"
        project.save()
        assert session_client.post(base(project), {"name": "n"}, format="json").status_code == 404

    def test_parent_in_same_project(self, session_client, project, create_user):
        parent = make_page(project, create_user)
        response = session_client.post(base(project), {"name": "kid", "parent": str(parent.id)}, format="json")
        assert response.status_code == 201
        assert Page.objects.get(pk=response.data["id"]).parent_id == parent.id

    def test_parent_in_other_project_is_400(self, session_client, project, create_user):
        other = Project.objects.create(name="Other", identifier="OT", workspace=project.workspace)
        parent = make_page(other, create_user)
        response = session_client.post(base(project), {"name": "kid", "parent": str(parent.id)}, format="json")
        assert response.status_code == 400
        assert not Page.objects.filter(name="kid").exists()

    def test_guest_cannot_create(self, api_client, project):
        guest = make_user("g@plane.so")
        join(project, guest, 5)
        assert client_for(guest, api_client).post(base(project), {"name": "n"}, format="json").status_code == 403

    def test_oversized_body_is_413(self, session_client, project, settings):
        settings.FILE_SIZE_LIMIT = 100
        response = session_client.post(
            base(project), {"name": "n", "description_html": "<p>" + "a" * 500 + "</p>"}, format="json"
        )
        assert response.status_code == 413


@pytest.mark.contract
class TestPatchGuards:
    @pytest.fixture(autouse=True)
    def live(self, mocker):
        return mocker.patch(LIVE)

    def test_unknown_key_400(self, session_client, project, create_user, live):
        page = make_page(project, create_user)
        response = session_client.patch(detail(project, page), {"name": "x", "access": 1}, format="json")
        assert response.status_code == 400
        live.is_page_loaded.assert_not_called()

    @pytest.mark.parametrize("key", ["description_json", "description_binary", "archived_at", "is_locked", "parent"])
    def test_other_fields_rejected(self, session_client, project, create_user, key):
        page = make_page(project, create_user)
        assert session_client.patch(detail(project, page), {key: "x"}, format="json").status_code == 400

    def test_empty_body_400(self, session_client, project, create_user):
        page = make_page(project, create_user)
        assert session_client.patch(detail(project, page), {}, format="json").status_code == 400

    def test_locked_400(self, session_client, project, create_user, live):
        page = make_page(project, create_user, is_locked=True)
        assert session_client.patch(detail(project, page), {"name": "x"}, format="json").status_code == 400
        live.is_page_loaded.assert_not_called()

    def test_archived_400(self, session_client, project, create_user, live):
        page = make_page(project, create_user, archived_at="2026-01-01")
        assert session_client.patch(detail(project, page), {"name": "x"}, format="json").status_code == 400
        live.is_page_loaded.assert_not_called()

    def test_guest_cannot_patch(self, api_client, project, create_user):
        guest = make_user("g@plane.so")
        join(project, guest, 5)
        page = make_page(project, create_user)
        assert (
            client_for(guest, api_client).patch(detail(project, page), {"name": "x"}, format="json").status_code == 403
        )

    def test_oversized_body_is_413(self, session_client, project, create_user, settings):
        settings.FILE_SIZE_LIMIT = 100
        page = make_page(project, create_user)
        response = session_client.patch(
            detail(project, page), {"description_html": "<p>" + "a" * 500 + "</p>"}, format="json"
        )
        assert response.status_code == 413


@pytest.mark.contract
class TestHtmlSizeCap:
    """PAGES_API_MAX_HTML_BYTES bounds description_html (decoded bytes) on create and update."""

    @pytest.fixture(autouse=True)
    def live(self, mocker):
        live = mocker.patch(LIVE)
        live.is_page_loaded.return_value = False
        return live

    @staticmethod
    def html_of(size):
        return "<p>" + "a" * (size - 7) + "</p>"

    def test_patch_over_limit_is_413(self, session_client, project, create_user, monkeypatch, live):
        monkeypatch.setenv("PAGES_API_MAX_HTML_BYTES", "1000")
        page = make_page(project, create_user)
        response = session_client.patch(detail(project, page), {"description_html": self.html_of(1001)}, format="json")
        assert response.status_code == 413
        assert response.json() == {"error": "description_html too large", "max_bytes": 1000}
        live.is_page_loaded.assert_not_called()
        live.rebase_page.assert_not_called()

    def test_patch_at_limit_passes(self, session_client, project, create_user, monkeypatch):
        monkeypatch.setenv("PAGES_API_MAX_HTML_BYTES", "1000")
        page = make_page(project, create_user)
        response = session_client.patch(detail(project, page), {"description_html": self.html_of(1000)}, format="json")
        assert response.status_code == 200

    def test_limit_counts_bytes_not_characters(self, session_client, project, create_user, monkeypatch):
        monkeypatch.setenv("PAGES_API_MAX_HTML_BYTES", "1000")
        page = make_page(project, create_user)
        html = "<p>" + "\u00e9" * 500 + "</p>"  # 507 characters, 1007 bytes
        assert len(html) < 1000 < len(html.encode())
        assert session_client.patch(detail(project, page), {"description_html": html}, format="json").status_code == 413

    def test_name_only_patch_is_not_affected(self, session_client, project, create_user, monkeypatch):
        monkeypatch.setenv("PAGES_API_MAX_HTML_BYTES", "10")
        page = make_page(project, create_user)
        assert session_client.patch(detail(project, page), {"name": "renamed"}, format="json").status_code == 200

    def test_create_over_limit_is_413(self, session_client, project, monkeypatch):
        monkeypatch.setenv("PAGES_API_MAX_HTML_BYTES", "1000")
        response = session_client.post(
            base(project), {"name": "n", "description_html": self.html_of(1001)}, format="json"
        )
        assert response.status_code == 413
        assert response.json()["max_bytes"] == 1000
        assert not Page.objects.filter(name="n").exists()

    def test_create_at_limit_passes(self, session_client, project, monkeypatch):
        monkeypatch.setenv("PAGES_API_MAX_HTML_BYTES", "1000")
        response = session_client.post(
            base(project), {"name": "n", "description_html": self.html_of(1000)}, format="json"
        )
        assert response.status_code == 201

    def test_default_limit_is_256_kib(self, session_client, project, create_user, monkeypatch):
        monkeypatch.delenv("PAGES_API_MAX_HTML_BYTES", raising=False)
        page = make_page(project, create_user)
        assert (
            session_client.patch(
                detail(project, page), {"description_html": self.html_of(262144)}, format="json"
            ).status_code
            == 200
        )
        assert (
            session_client.patch(
                detail(project, page), {"description_html": self.html_of(262145)}, format="json"
            ).status_code
            == 413
        )

    @pytest.mark.parametrize("value", ["abc", "0", "-5", ""])
    def test_invalid_setting_falls_back_to_default(self, session_client, project, create_user, monkeypatch, value):
        monkeypatch.setenv("PAGES_API_MAX_HTML_BYTES", value)
        page = make_page(project, create_user)
        assert (
            session_client.patch(
                detail(project, page), {"description_html": self.html_of(262145)}, format="json"
            ).status_code
            == 413
        )


@pytest.mark.contract
class TestPatchNoBinary:
    def test_writes_directly_when_not_loaded(
        self, session_client, project, create_user, mocker, celery_mocks, django_capture_on_commit_callbacks
    ):
        live = mocker.patch(LIVE)
        live.is_page_loaded.return_value = False
        page = make_page(project, create_user)
        with django_capture_on_commit_callbacks(execute=True):
            response = session_client.patch(
                detail(project, page), {"name": "renamed", "description_html": "<p>new</p>"}, format="json"
            )
        assert response.status_code == 200
        page.refresh_from_db()
        assert (page.name, page.description_html) == ("renamed", "<p>new</p>")
        assert not page.description_binary
        live.rebase_page.assert_not_called()
        celery_mocks["transaction"].assert_called_once_with(
            new_description_html="<p>new</p>", old_description_html="<p>hello</p>", page_id=page.id
        )
        celery_mocks["version"].assert_called_once()
        assert json.loads(celery_mocks["version"].call_args.kwargs["existing_instance"]) == {
            "description_html": "<p>hello</p>"
        }

    def test_html_is_sanitized(self, session_client, project, create_user, mocker):
        mocker.patch(LIVE).is_page_loaded.return_value = False
        page = make_page(project, create_user)
        session_client.patch(detail(project, page), {"description_html": "<p>a</p><script>x</script>"}, format="json")
        page.refresh_from_db()
        assert "script" not in page.description_html

    def test_empty_html_becomes_empty_paragraph(self, session_client, project, create_user, mocker):
        mocker.patch(LIVE).is_page_loaded.return_value = False
        page = make_page(project, create_user)
        session_client.patch(detail(project, page), {"description_html": ""}, format="json")
        page.refresh_from_db()
        assert page.description_html == "<p></p>"

    def test_empty_bytes_binary_counts_as_no_binary(self, session_client, project, create_user, mocker):
        live = mocker.patch(LIVE)
        live.is_page_loaded.return_value = False
        page = make_page(project, create_user, description_binary=b"")
        assert session_client.patch(detail(project, page), {"name": "n"}, format="json").status_code == 200
        live.rebase_page.assert_not_called()

    @pytest.mark.parametrize("presence", [True, None])
    def test_loaded_or_unknown_conflicts_and_writes_nothing(
        self, session_client, project, create_user, mocker, celery_mocks, presence
    ):
        live = mocker.patch(LIVE)
        live.is_page_loaded.return_value = presence
        page = make_page(project, create_user)
        response = session_client.patch(
            detail(project, page), {"name": "x", "description_html": "<p>n</p>"}, format="json"
        )
        assert response.status_code == 409
        assert response.data == OPEN_MSG
        page.refresh_from_db()
        assert (page.name, page.description_html) == ("A page", "<p>hello</p>")
        celery_mocks["transaction"].assert_not_called()
        celery_mocks["version"].assert_not_called()

    def test_no_live_url_conflicts(self, session_client, project, create_user, settings):
        settings.LIVE_URL = None
        page = make_page(project, create_user)
        response = session_client.patch(detail(project, page), {"name": "x"}, format="json")
        assert response.status_code == 409
        assert response.data == OPEN_MSG


@pytest.mark.contract
class TestPatchWithBinary:
    def test_rebase_then_presence_then_save(
        self, session_client, project, create_user, mocker, celery_mocks, django_capture_on_commit_callbacks
    ):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = rebase_answer("<p>rebased</p>")
        live.is_page_loaded.return_value = False
        page = binary_page(project, create_user)
        with django_capture_on_commit_callbacks(execute=True):
            response = session_client.patch(
                detail(project, page), {"name": "renamed", "description_html": "<p>new</p>"}, format="json"
            )
        assert response.status_code == 200
        page.refresh_from_db()
        assert bytes(page.description_binary) == b"\x09\x08\x07\x06\x05"
        assert page.description_html == "<p>rebased</p>"
        assert page.description_json == {"type": "doc"}
        assert page.name == "renamed"
        args = live.rebase_page.call_args[0]
        assert args[0] == page.id and base64.b64decode(args[1]) == b"\x01\x02\x03" and args[2] == "<p>new</p>"
        celery_mocks["transaction"].assert_called_once_with(
            new_description_html="<p>rebased</p>", old_description_html="<p>hello</p>", page_id=page.id
        )

    def test_presence_is_checked_after_rebase(self, session_client, project, create_user, mocker):
        order = []
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.side_effect = lambda *a, **k: order.append("rebase") or rebase_answer()
        live.is_page_loaded.side_effect = lambda *a, **k: order.append("presence") or False
        page = binary_page(project, create_user)
        response = session_client.patch(detail(project, page), {"description_html": "<p>n</p>"}, format="json")
        assert response.status_code == 200
        assert order[:2] == ["rebase", "presence"]

    @pytest.mark.parametrize("presence", [True, None])
    def test_loaded_or_unknown_after_rebase_conflicts_and_writes_nothing(
        self, session_client, project, create_user, mocker, celery_mocks, presence
    ):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = rebase_answer()
        live.is_page_loaded.return_value = presence
        page = binary_page(project, create_user)
        response = session_client.patch(
            detail(project, page), {"name": "x", "description_html": "<p>n</p>"}, format="json"
        )
        assert response.status_code == 409
        assert response.data == OPEN_MSG
        page.refresh_from_db()
        assert bytes(page.description_binary) == b"\x01\x02\x03"
        assert (page.name, page.description_html) == ("A page", "<p>hello</p>")
        celery_mocks["transaction"].assert_not_called()

    def test_rebase_failure_is_503(self, session_client, project, create_user, mocker):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.side_effect = live_pages.LiveServiceError("down")
        page = binary_page(project, create_user)
        response = session_client.patch(detail(project, page), {"description_html": "<p>n</p>"}, format="json")
        assert response.status_code == 503
        assert response.data == LIVE_DOWN_MSG
        live.is_page_loaded.assert_not_called()
        page.refresh_from_db()
        assert page.description_html == "<p>hello</p>"

    @pytest.mark.parametrize(
        "answer",
        [
            {},
            {"description_binary": ""},
            {"description_binary": "%%%not-base64"},
            {"description_binary": "AQID"},
            {"description_html": "<p>x</p>"},
        ],
    )
    def test_invalid_rebase_result_is_503(self, session_client, project, create_user, mocker, answer):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = answer
        page = binary_page(project, create_user)
        response = session_client.patch(detail(project, page), {"description_html": "<p>n</p>"}, format="json")
        assert response.status_code == 503
        live.is_page_loaded.assert_not_called()

    def test_name_only_still_rebases(
        self, session_client, project, create_user, mocker, celery_mocks, django_capture_on_commit_callbacks
    ):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = {"description_binary": rebase_answer()["description_binary"]}
        live.is_page_loaded.return_value = False
        page = binary_page(project, create_user)
        with django_capture_on_commit_callbacks(execute=True):
            response = session_client.patch(detail(project, page), {"name": "n"}, format="json")
        assert response.status_code == 200
        args = live.rebase_page.call_args[0]
        assert args[2] is None and args[3] == "n"
        page.refresh_from_db()
        assert bytes(page.description_binary) == b"\x09\x08\x07\x06\x05"
        assert (page.name, page.description_html) == ("n", "<p>hello</p>")
        celery_mocks["transaction"].assert_not_called()
        celery_mocks["version"].assert_called_once()

    def test_name_only_invalid_rebase_result_is_503(self, session_client, project, create_user, mocker):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = {}
        page = binary_page(project, create_user)
        assert session_client.patch(detail(project, page), {"name": "n"}, format="json").status_code == 503
        page.refresh_from_db()
        assert page.name == "A page"

    def test_empty_html_becomes_empty_paragraph(self, session_client, project, create_user, mocker):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = {"description_binary": rebase_answer()["description_binary"]}
        live.is_page_loaded.return_value = False
        page = binary_page(project, create_user)
        assert session_client.patch(detail(project, page), {"description_html": ""}, format="json").status_code == 200
        assert live.rebase_page.call_args[0][2] == "<p></p>"
        page.refresh_from_db()
        assert page.description_html == "<p></p>"

    @pytest.mark.parametrize("live_url", [None, "http://localhost:1/live/"])
    def test_live_unreachable_is_503_through_the_real_client(
        self, session_client, project, create_user, settings, mocker, live_url
    ):
        import requests

        settings.LIVE_URL = live_url
        mocker.patch("plane.utils.live_pages.requests.post", side_effect=requests.Timeout("slow"))
        page = binary_page(project, create_user)
        response = session_client.patch(detail(project, page), {"description_html": "<p>n</p>"}, format="json")
        assert response.status_code == 503
        assert response.data == LIVE_DOWN_MSG
        page.refresh_from_db()
        assert page.description_html == "<p>hello</p>"

    def test_track_page_version_creates_a_version_row(
        self, session_client, project, create_user, mocker, celery_mocks, django_capture_on_commit_callbacks
    ):
        from plane.bgtasks.page_version_task import track_page_version
        from plane.db.models import PageVersion

        mocker.patch(LIVE).is_page_loaded.return_value = False
        page = make_page(project, create_user)
        with django_capture_on_commit_callbacks(execute=True):
            session_client.patch(detail(project, page), {"description_html": "<p>v2</p>"}, format="json")
        kwargs = celery_mocks["version"].call_args.kwargs
        track_page_version(**kwargs)
        version = PageVersion.objects.get(page=page)
        assert version.description_html == "<p>v2</p>"
        assert version.description_json == {}

    def test_post_commit_recheck_warns_with_page_id_only(
        self, session_client, project, create_user, mocker, caplog, django_capture_on_commit_callbacks
    ):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = rebase_answer("<p>SECRET-BODY</p>")
        live.is_page_loaded.side_effect = [False, True]
        page = binary_page(project, create_user)
        with caplog.at_level("WARNING", logger="plane.api"):
            with django_capture_on_commit_callbacks(execute=True):
                session_client.patch(detail(project, page), {"description_html": "<p>n</p>"}, format="json")
        messages = [r.getMessage() for r in caplog.records if r.levelname == "WARNING"]
        assert any(str(page.id) in m for m in messages)
        assert not any("SECRET-BODY" in m for m in messages)


@pytest.mark.contract
class TestArchive:
    def test_owner_member_can_archive_and_unarchive(self, api_client, project):
        member = make_user("m@plane.so")
        join(project, member, 15)
        page = make_page(project, member)
        client = client_for(member, api_client)
        assert client.post(archive_url(project, page)).status_code == 200
        page.refresh_from_db()
        assert page.archived_at is not None
        assert client.delete(archive_url(project, page)).status_code == 204
        page.refresh_from_db()
        assert page.archived_at is None

    def test_admin_can_archive_others_page(self, session_client, project):
        member = make_user("m@plane.so")
        join(project, member, 15)
        page = make_page(project, member)
        assert session_client.post(archive_url(project, page)).status_code == 200

    def test_non_owner_member_post_is_400(self, api_client, project, create_user):
        member = make_user("m@plane.so")
        join(project, member, 15)
        page = make_page(project, create_user)
        assert client_for(member, api_client).post(archive_url(project, page)).status_code == 400
        page.refresh_from_db()
        assert page.archived_at is None

    def test_non_owner_member_delete_is_403(self, api_client, project, create_user):
        member = make_user("m@plane.so")
        join(project, member, 15)
        page = make_page(project, create_user, archived_at="2026-01-01")
        assert client_for(member, api_client).delete(archive_url(project, page)).status_code == 403
        page.refresh_from_db()
        assert page.archived_at is not None

    def test_guest_cannot_archive(self, api_client, project, create_user):
        guest = make_user("g@plane.so")
        join(project, guest, 5)
        page = make_page(project, create_user)
        assert client_for(guest, api_client).post(archive_url(project, page)).status_code == 403

    def test_archive_covers_descendants(self, session_client, project, create_user):
        parent = make_page(project, create_user)
        child = make_page(project, create_user, parent=parent)
        session_client.post(archive_url(project, parent))
        child.refresh_from_db()
        assert child.archived_at is not None

    def test_disabled_flag_is_404(self, monkeypatch, session_client, project, create_user):
        page = make_page(project, create_user)
        monkeypatch.setenv("PAGES_API_ENABLED", "")
        assert session_client.post(archive_url(project, page)).status_code == 404


@pytest.mark.unit
class TestLiveClient:
    def test_presence_sends_secret_header_and_timeout(self, mocker, settings, monkeypatch):
        settings.LIVE_URL = "http://localhost:3100/live/"
        monkeypatch.setenv("LIVE_SERVER_SECRET_KEY", "k-test")
        get = mocker.patch("plane.utils.live_pages.requests.get")
        get.return_value.status_code = 200
        get.return_value.json.return_value = {"loaded": False}
        pid = uuid4()
        assert live_pages.is_page_loaded(pid) is False
        assert get.call_args[0][0] == f"http://localhost:3100/live/fork/pages/{pid}/loaded"
        assert get.call_args.kwargs["timeout"] == 3
        assert get.call_args.kwargs["headers"]["live-server-secret-key"] == "k-test"

    @pytest.mark.parametrize("payload", [{"loaded": "no"}, {}, []])
    def test_presence_bad_answer_is_unknown(self, mocker, settings, payload):
        settings.LIVE_URL = "http://localhost:3100/live/"
        get = mocker.patch("plane.utils.live_pages.requests.get")
        get.return_value.status_code = 200
        get.return_value.json.return_value = payload
        assert live_pages.is_page_loaded(uuid4()) is None

    def test_presence_failure_is_unknown_and_secret_not_logged(self, mocker, settings, monkeypatch, caplog):
        import requests

        settings.LIVE_URL = "http://localhost:3100/live/"
        monkeypatch.setenv("LIVE_SERVER_SECRET_KEY", "k-test")
        mocker.patch("plane.utils.live_pages.requests.get", side_effect=requests.Timeout("boom"))
        with caplog.at_level("WARNING", logger="plane.api"):
            assert live_pages.is_page_loaded(uuid4()) is None
        assert "k-test" not in caplog.text

    def test_presence_without_live_url_is_unknown(self, settings):
        settings.LIVE_URL = None
        assert live_pages.is_page_loaded(uuid4()) is None

    def test_rebase_request_shape(self, mocker, settings, monkeypatch):
        settings.LIVE_URL = "http://localhost:3100/live/"
        monkeypatch.setenv("LIVE_SERVER_SECRET_KEY", "k-test")
        post = mocker.patch("plane.utils.live_pages.requests.post")
        post.return_value.status_code = 200
        post.return_value.json.return_value = {"description_binary": "AA=="}
        assert live_pages.rebase_page(uuid4(), "AQ==", None, "New name") == {"description_binary": "AA=="}
        assert post.call_args[0][0] == "http://localhost:3100/live/fork/pages/rebase"
        assert post.call_args.kwargs["timeout"] == 10
        assert post.call_args.kwargs["json"] == {"base_binary": "AQ==", "description_html": None, "name": "New name"}
        headers = post.call_args.kwargs["headers"]
        assert headers["Content-Type"] == "application/vnd.plane-fork.rebase+json"
        assert headers["live-server-secret-key"] == "k-test"

    def test_rebase_failures_raise(self, mocker, settings):
        settings.LIVE_URL = "http://localhost:3100/live/"
        post = mocker.patch("plane.utils.live_pages.requests.post")
        post.return_value.status_code = 500
        with pytest.raises(live_pages.LiveServiceError):
            live_pages.rebase_page(uuid4(), "AQ==", "<p>x</p>", None)
        settings.LIVE_URL = None
        with pytest.raises(live_pages.LiveServiceError):
            live_pages.rebase_page(uuid4(), "AQ==", "<p>x</p>", None)


@pytest.mark.unit
def test_version_task_uses_description_json():
    import inspect

    from plane.bgtasks import page_version_task

    source = inspect.getsource(page_version_task)
    assert "page.description," not in source and "page.description\n" not in source


@pytest.mark.contract
class TestPresenceFailuresAtViewLevel:
    """Branch (a) through the real live client: every failure mode counts as unknown."""

    @pytest.mark.parametrize(
        "kind",
        ["timeout", "http_500", "not_json", "bad_shape"],
    )
    def test_unknown_presence_conflicts(self, session_client, project, create_user, settings, mocker, kind):
        import requests

        settings.LIVE_URL = "http://localhost:3100/live/"
        get = mocker.patch("plane.utils.live_pages.requests.get")
        if kind == "timeout":
            get.side_effect = requests.Timeout("slow")
        else:
            get.return_value.status_code = 500 if kind == "http_500" else 200
            if kind == "not_json":
                get.return_value.json.side_effect = ValueError("nope")
            else:
                get.return_value.json.return_value = {"loaded": "maybe"}
        page = make_page(project, create_user)
        response = session_client.patch(detail(project, page), {"name": "x"}, format="json")
        assert response.status_code == 409
        assert response.data == OPEN_MSG
        page.refresh_from_db()
        assert page.name == "A page"


@pytest.mark.contract
class TestAccessRules:
    def test_workspace_admin_not_project_member_is_403(self, api_client, project):
        admin = make_user("wsadmin@plane.so")
        WorkspaceMember.objects.create(workspace=project.workspace, member=admin, role=20)
        assert client_for(admin, api_client).get(base(project)).status_code == 403

    def test_guest_sees_only_own_pages_without_view_all(self, api_client, project, create_user):
        guest = make_user("g@plane.so")
        join(project, guest, 5)
        make_page(project, create_user, name="theirs")
        mine = make_page(project, guest, name="mine")
        response = client_for(guest, api_client).get(base(project))
        assert [r["id"] for r in response.data["results"]] == [str(mine.id)]

    def test_guest_sees_public_pages_with_view_all(self, api_client, project, create_user):
        project.guest_view_all_features = True
        project.save()
        guest = make_user("g@plane.so")
        join(project, guest, 5)
        theirs = make_page(project, create_user, name="theirs")
        make_page(project, create_user, name="private", access=Page.PRIVATE_ACCESS)
        response = client_for(guest, api_client).get(base(project))
        assert [r["id"] for r in response.data["results"]] == [str(theirs.id)]
        assert client_for(guest, api_client).get(detail(project, theirs)).status_code == 200

    def test_page_linked_only_to_other_project_is_403(self, session_client, project, create_user):
        other = Project.objects.create(name="B", identifier="BB", workspace=project.workspace)
        ProjectMember.objects.create(project=other, member=create_user, role=20, is_active=True)
        page = make_page(other, create_user)
        assert session_client.get(detail(project, page)).status_code == 403
        assert session_client.patch(detail(project, page), {"name": "x"}, format="json").status_code == 403
        assert session_client.post(archive_url(project, page)).status_code == 403

    def test_rate_limit_headers_present_with_api_key(self, api_key_client, project):
        response = api_key_client.get(base(project))
        assert response.status_code == 200
        assert "X-RateLimit-Remaining" in response


@pytest.mark.contract
class TestListFiltersAndOrdering:
    def test_cursor_pagination(self, session_client, project, create_user):
        pages = [make_page(project, create_user, name=f"p{i}") for i in range(3)]
        first = session_client.get(base(project) + "?per_page=2")
        assert first.status_code == 200
        assert len(first.data["results"]) == 2
        assert first.data["next_page_results"] is True
        second = session_client.get(base(project) + f"?per_page=2&cursor={first.data['next_cursor']}")
        assert len(second.data["results"]) == 1
        seen = {r["id"] for r in first.data["results"]} | {r["id"] for r in second.data["results"]}
        assert seen == {str(p.id) for p in pages}
        back = session_client.get(base(project) + f"?per_page=2&cursor={second.data['prev_cursor']}")
        assert {r["id"] for r in back.data["results"]} == {r["id"] for r in first.data["results"]}

    def test_filters(self, session_client, project, create_user):
        parent = make_page(project, create_user, name="parent")
        kid = make_page(project, create_user, name="kid", parent=parent, external_id="x1", external_source="sync")
        make_page(project, create_user, name="other", external_id="x2", external_source="sync")
        ids = lambda qs: [r["id"] for r in session_client.get(base(project) + qs).data["results"]]  # noqa: E731
        assert ids(f"?parent_id={parent.id}") == [str(kid.id)]
        assert ids("?external_id=x1") == [str(kid.id)]
        assert sorted(ids("?external_source=sync")) == sorted(ids("?external_id=x1") + ids("?external_id=x2"))
        assert ids("?external_source=sync&external_id=x2") != [str(kid.id)]
        assert ids("?external_source=none") == []

    def test_order_by_allowlist(self, session_client, project, create_user):
        make_page(project, create_user, name="b")
        make_page(project, create_user, name="a")
        names = lambda qs: [r["name"] for r in session_client.get(base(project) + qs).data["results"]]  # noqa: E731
        assert names("?order_by=name") == ["a", "b"]
        assert names("?order_by=-name") == ["b", "a"]

    @pytest.mark.parametrize("bad", ["owned_by__password", "--name", "description_binary", "workspace__owner"])
    def test_disallowed_order_by_falls_back_to_default(self, session_client, project, create_user, bad):
        first = make_page(project, create_user, name="first")
        second = make_page(project, create_user, name="second")
        response = session_client.get(base(project) + f"?order_by={bad}")
        assert response.status_code == 200
        assert [r["id"] for r in response.data["results"]] == [str(second.id), str(first.id)]


@pytest.mark.contract
@pytest.mark.django_db(transaction=True)
class TestConcurrentCreate:
    def test_parallel_creates_with_same_external_pair_give_one_201_and_one_409(self, project, api_token):
        import threading

        from django.db import connection
        from rest_framework.test import APIClient

        body = {"name": "n", "external_id": "race", "external_source": "sync"}
        results = []
        barrier = threading.Barrier(4)

        def worker():
            try:
                client = APIClient()
                client.credentials(HTTP_X_API_KEY=api_token.token)
                barrier.wait(timeout=10)
                results.append(client.post(base(project), body, format="json").status_code)
            finally:
                connection.close()

        threads = [threading.Thread(target=worker) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=60)
        assert sorted(results) == [201, 409, 409, 409]
        assert Page.objects.filter(external_id="race").count() == 1


@pytest.mark.contract
class TestRebaseResultStorage:
    """What is stored when the live service returns empty or partial values (branch b)."""

    def _patch(self, session_client, project, create_user, mocker, answer, body):
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = answer
        live.is_page_loaded.return_value = False
        page = binary_page(project, create_user)
        response = session_client.patch(detail(project, page), body, format="json")
        page.refresh_from_db()
        return response, page

    def test_returned_empty_html_is_stored_as_empty_paragraph(self, session_client, project, create_user, mocker):
        answer = {**rebase_answer(), "description_html": ""}
        response, page = self._patch(session_client, project, create_user, mocker, answer, {"name": "n"})
        assert response.status_code == 200
        assert page.description_html == "<p></p>"

    def test_returned_empty_json_is_stored(self, session_client, project, create_user, mocker):
        answer = {**rebase_answer(), "description_json": {}}
        page_json = {"type": "doc"}
        live = mocker.patch(LIVE)
        live.LiveServiceError = live_pages.LiveServiceError
        live.rebase_page.return_value = answer
        live.is_page_loaded.return_value = False
        page = binary_page(project, create_user, description_json=page_json)
        assert session_client.patch(detail(project, page), {"name": "n"}, format="json").status_code == 200
        page.refresh_from_db()
        assert page.description_json == {}

    def test_missing_html_and_json_keep_stored_values(self, session_client, project, create_user, mocker):
        answer = {"description_binary": rebase_answer()["description_binary"]}
        response, page = self._patch(session_client, project, create_user, mocker, answer, {"name": "n"})
        assert response.status_code == 200
        assert page.description_html == "<p>hello</p>"
