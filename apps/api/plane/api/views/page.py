# SPDX-License-Identifier: AGPL-3.0-only

# Python imports
import base64
import hashlib
import json
import logging
import os
from datetime import date

# Django imports
from django.conf import settings
from django.core.exceptions import RequestDataTooBig
from django.db import connection, transaction
from django.db.models import Q, UUIDField, Value

# Third party imports
from rest_framework import status
from rest_framework.exceptions import NotFound
from rest_framework.response import Response

# Module imports
from plane.api.serializers.page import (
    PageAPISerializer,
    PageCreateAPISerializer,
    PageListAPISerializer,
    PageUpdateAPISerializer,
)
from plane.app.permissions import ROLE
from plane.app.permissions.page import ProjectPagePermission
from plane.app.serializers import PageBinaryUpdateSerializer
from plane.bgtasks.page_transaction_task import page_transaction
from plane.bgtasks.page_version_task import track_page_version
from plane.db.models import Page, Project, ProjectMember, ProjectPage, UserFavorite
from plane.utils import live_pages
from plane.utils.order_queryset import PAGE_ORDER_BY_ALLOWLIST, sanitize_order_by

from .base import BaseAPIView

logger = logging.getLogger("plane.api")

OPEN_IN_EDITOR = {"error": "page is open in an editor; retry later"}
LIVE_UNAVAILABLE = {"error": "live service unavailable, page not updated"}


def _pages_api_enabled():
    return os.environ.get("PAGES_API_ENABLED") == "1"


DEFAULT_MAX_HTML_BYTES = 262144


def _max_html_bytes():
    """Cap on description_html in bytes (PAGES_API_MAX_HTML_BYTES), read per call. The live service
    converts the html on a rebase, and that cost grows faster than linearly with its size."""
    try:
        value = int(os.environ.get("PAGES_API_MAX_HTML_BYTES", ""))
    except ValueError:
        return DEFAULT_MAX_HTML_BYTES
    return value if value > 0 else DEFAULT_MAX_HTML_BYTES


def _has_binary(page):
    return bool(page.description_binary)


def _external_lock_key(project_id, external_source, external_id):
    digest = hashlib.sha256(f"{project_id}:{external_source}:{external_id}".encode()).digest()
    return int.from_bytes(digest[:8], "big", signed=True)


class HtmlTooLarge(Exception):
    def __init__(self, limit):
        super().__init__("description_html too large")
        self.limit = limit


class PageBaseAPIEndpoint(BaseAPIView):
    permission_classes = [ProjectPagePermission]

    def initial(self, request, *args, **kwargs):
        # The whole surface is invisible unless the deployment switches it on.
        if not _pages_api_enabled():
            raise NotFound()
        super().initial(request, *args, **kwargs)

    def handle_exception(self, exc):
        if isinstance(exc, RequestDataTooBig):
            return Response({"error": "request body too large"}, status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        if isinstance(exc, HtmlTooLarge):
            return Response(
                {"error": "description_html too large", "max_bytes": exc.limit},
                status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            )
        return super().handle_exception(exc)

    def check_body_size(self, request):
        """Django's memory limit does not apply to streamed json bodies, so cap explicitly."""
        try:
            length = int(request.META.get("CONTENT_LENGTH") or 0)
        except ValueError:
            length = 0
        if length > settings.FILE_SIZE_LIMIT:
            raise RequestDataTooBig()

    def check_html_size(self, request):
        """Cap description_html by its decoded size in bytes, before the sanitiser or live see it
        (the Content-Length check above does not bound it: it is only the whole body)."""
        data = request.data
        html = data.get("description_html") if hasattr(data, "get") else None
        limit = _max_html_bytes()
        if isinstance(html, str) and len(html.encode("utf-8")) > limit:
            raise HtmlTooLarge(limit)

    def base_queryset(self, slug, project_id):
        """Pages of the project in the url that the caller may see (design 2.2)."""
        user = self.request.user
        queryset = (
            Page.objects.filter(
                workspace__slug=slug,
                project_pages__project_id=project_id,
                project_pages__deleted_at__isnull=True,
                project_pages__project__archived_at__isnull=True,
            )
            .filter(Q(owned_by=user) | Q(access=Page.PUBLIC_ACCESS))
            .annotate(project_id=Value(project_id, output_field=UUIDField()))
        )
        project = Project.objects.filter(pk=project_id).first()
        is_guest = ProjectMember.objects.filter(
            project_id=project_id, member=user, role=ROLE.GUEST.value, is_active=True
        ).exists()
        if is_guest and project is not None and not project.guest_view_all_features:
            queryset = queryset.filter(owned_by=user)
        return queryset.distinct()

    def get_page(self, slug, project_id, page_id):
        page = self.base_queryset(slug, project_id).filter(pk=page_id).first()
        if page is None:
            raise NotFound()
        return page

    def get_project(self, slug, project_id):
        project = Project.objects.filter(pk=project_id, workspace__slug=slug, archived_at__isnull=True).first()
        if project is None:
            raise NotFound()
        return project


class PageListCreateAPIEndpoint(PageBaseAPIEndpoint):
    """List and create pages of a project."""

    def get(self, request, slug, project_id):
        queryset = self.base_queryset(slug, project_id)
        if request.GET.get("archived", "false").lower() == "true":
            queryset = queryset.filter(archived_at__isnull=False)
        else:
            queryset = queryset.filter(archived_at__isnull=True)
        for param, field in (
            ("parent_id", "parent_id"),
            ("external_source", "external_source"),
            ("external_id", "external_id"),
        ):
            value = request.GET.get(param)
            if value:
                queryset = queryset.filter(**{field: value})
        order_by = sanitize_order_by(request.GET.get("order_by"), PAGE_ORDER_BY_ALLOWLIST, default="-created_at")
        return self.paginate(
            request=request,
            queryset=queryset.order_by(order_by, "-created_at"),
            on_results=lambda pages: PageListAPISerializer(pages, many=True).data,
        )

    def post(self, request, slug, project_id):
        self.check_body_size(request)
        self.check_html_size(request)
        project = self.get_project(slug, project_id)
        if not project.page_view:
            return Response({"error": "Pages are disabled for this project"}, status=status.HTTP_400_BAD_REQUEST)

        serializer = PageCreateAPISerializer(data=request.data, context={"project": project})
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        data = serializer.validated_data

        with transaction.atomic():
            if data["external_id"] and data["external_source"]:
                with connection.cursor() as cursor:
                    cursor.execute(
                        "SELECT pg_advisory_xact_lock(%s)",
                        [_external_lock_key(project.id, data["external_source"], data["external_id"])],
                    )
                existing = (
                    Page.objects.filter(
                        workspace_id=project.workspace_id,
                        external_id=data["external_id"],
                        external_source=data["external_source"],
                        project_pages__project_id=project.id,
                        project_pages__deleted_at__isnull=True,
                    )
                    .values_list("id", flat=True)
                    .first()
                )
                if existing is not None:
                    return Response(
                        {
                            "error": "Page with the same external id and external source already exists",
                            "id": str(existing),
                        },
                        status=status.HTTP_409_CONFLICT,
                    )

            page = Page.objects.create(
                workspace_id=project.workspace_id,
                name=data["name"],
                description_html=data["description_html"],
                description_binary=None,
                description_json={},
                access=data["access"],
                color=data["color"],
                parent_id=data["parent"],
                external_id=data["external_id"],
                external_source=data["external_source"],
                owned_by_id=request.user.id,
            )
            ProjectPage.objects.create(
                workspace_id=project.workspace_id,
                project_id=project.id,
                page_id=page.id,
            )
            stored_html = page.description_html
            transaction.on_commit(
                lambda: page_transaction.delay(
                    new_description_html=stored_html,
                    old_description_html=None,
                    page_id=page.id,
                )
            )

        page = self.get_page(slug, project_id, page.id)
        return Response(PageAPISerializer(page).data, status=status.HTTP_201_CREATED)


class PageDetailAPIEndpoint(PageBaseAPIEndpoint):
    """Retrieve a page, or update its name and html while it is not open in an editor."""

    def get(self, request, slug, project_id, page_id):
        page = self.get_page(slug, project_id, page_id)
        return Response(PageAPISerializer(page).data, status=status.HTTP_200_OK)

    def patch(self, request, slug, project_id, page_id):
        self.check_body_size(request)
        self.check_html_size(request)
        page = self.get_page(slug, project_id, page_id)

        # Guards: unknown key, empty body, locked, archived.
        if not hasattr(request.data, "keys"):
            return Response({"error": "Body must be an object"}, status=status.HTTP_400_BAD_REQUEST)
        serializer = PageUpdateAPISerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        data = serializer.validated_data
        if page.is_locked:
            return Response({"error": "Page is locked"}, status=status.HTTP_400_BAD_REQUEST)
        if page.archived_at:
            return Response({"error": "Page is archived"}, status=status.HTTP_400_BAD_REQUEST)

        with transaction.atomic():
            page = Page.objects.select_for_update().get(pk=page.id)
            if page.is_locked:
                return Response({"error": "Page is locked"}, status=status.HTTP_400_BAD_REQUEST)
            if page.archived_at:
                return Response({"error": "Page is archived"}, status=status.HTTP_400_BAD_REQUEST)

            old_html = page.description_html
            has_html = "description_html" in data

            if not _has_binary(page):
                # (a) No stored document: live would rebuild it from the html on next open,
                # so the html can be written directly, but only if nobody has it open.
                if live_pages.is_page_loaded(page.id) is not False:
                    return Response(OPEN_IN_EDITOR, status=status.HTTP_409_CONFLICT)
                update_fields = []
                if "name" in data:
                    page.name = data["name"]
                    update_fields.append("name")
                if has_html:
                    page.description_html = data["description_html"]
                    update_fields.append("description_html")
            else:
                # (b) Stored document: fold the change (html and/or name) into it through the live
                # service; the title lives in the binary too, so a name-only change rebases as well.
                try:
                    result = live_pages.rebase_page(
                        page.id,
                        base64.b64encode(bytes(page.description_binary)).decode(),
                        data.get("description_html"),
                        data.get("name"),
                    )
                except live_pages.LiveServiceError:
                    return Response(LIVE_UNAVAILABLE, status=status.HTTP_503_SERVICE_UNAVAILABLE)
                rebased = PageBinaryUpdateSerializer(data=result)
                if not rebased.is_valid() or not rebased.validated_data.get("description_binary"):
                    return Response(LIVE_UNAVAILABLE, status=status.HTTP_503_SERVICE_UNAVAILABLE)
                # The presence check comes after the rebase so a page opened meanwhile is caught.
                if live_pages.is_page_loaded(page.id) is not False:
                    return Response(OPEN_IN_EDITOR, status=status.HTTP_409_CONFLICT)
                validated = rebased.validated_data
                update_fields = ["description_binary"]
                page.description_binary = validated["description_binary"]
                if "name" in data:
                    page.name = data["name"]
                    update_fields.append("name")
                if "description_html" in validated:
                    page.description_html = validated["description_html"] or "<p></p>"
                    update_fields.append("description_html")
                elif data.get("description_html"):
                    page.description_html = data["description_html"]
                    update_fields.append("description_html")
                if validated.get("description_json") is not None:
                    page.description_json = validated["description_json"]
                    update_fields.append("description_json")

            page.save(update_fields=[*update_fields, "description_stripped", "updated_at", "updated_by"])
            stored_html = page.description_html
            page_pk = page.id
            user_id = request.user.id
            html_changed = has_html
            transaction.on_commit(lambda: self._after_commit(page_pk, old_html, stored_html, user_id, html_changed))

        page = self.get_page(slug, project_id, page_id)
        return Response(PageAPISerializer(page).data, status=status.HTTP_200_OK)

    @staticmethod
    def _after_commit(page_id, old_html, stored_html, user_id, html_changed):
        if html_changed:
            page_transaction.delay(
                new_description_html=stored_html,
                old_description_html=old_html,
                page_id=page_id,
            )
        track_page_version.delay(
            page_id=page_id,
            existing_instance=json.dumps({"description_html": old_html}),
            user_id=user_id,
        )
        # Best effort: someone may have opened the page while we were writing.
        try:
            if live_pages.is_page_loaded(page_id) is True:
                logger.warning("page %s was opened in an editor during an api update", page_id)
        except Exception as exc:
            logger.warning("presence re-check failed for page %s (%s)", page_id, type(exc).__name__)


class PageArchiveAPIEndpoint(PageBaseAPIEndpoint):
    """Archive (POST) and unarchive (DELETE) a page; owner or project admin only."""

    def _check_owner_or_admin(self, request, project_id, page):
        if request.user.id == page.owned_by_id:
            return True
        return ProjectMember.objects.filter(
            project_id=project_id, member=request.user, is_active=True, role=ROLE.ADMIN.value
        ).exists()

    def post(self, request, slug, project_id, page_id):
        from plane.app.views.page.base import unarchive_archive_page_and_descendants

        page = self.get_page(slug, project_id, page_id)
        if not self._check_owner_or_admin(request, project_id, page):
            return Response(
                {"error": "Only the owner or admin can archive the page"}, status=status.HTTP_400_BAD_REQUEST
            )
        UserFavorite.objects.filter(
            entity_type="page", entity_identifier=page.id, project_id=project_id, workspace__slug=slug
        ).delete()
        unarchive_archive_page_and_descendants(page.id, date.today())
        return Response({"archived_at": str(date.today())}, status=status.HTTP_200_OK)

    def delete(self, request, slug, project_id, page_id):
        from plane.app.views.page.base import unarchive_archive_page_and_descendants

        page = self.get_page(slug, project_id, page_id)
        if not self._check_owner_or_admin(request, project_id, page):
            return Response(
                {"error": "Only the owner or admin can unarchive the page"}, status=status.HTTP_403_FORBIDDEN
            )
        # An archived parent would break the hierarchy, so detach the page from it.
        if page.parent_id and page.parent.archived_at:
            page.parent = None
            page.save(update_fields=["parent"])
        unarchive_archive_page_and_descendants(page.id, None)
        return Response(status=status.HTTP_204_NO_CONTENT)
