# SPDX-License-Identifier: AGPL-3.0-only

from django.urls import path

from plane.api.views import (
    PageArchiveAPIEndpoint,
    PageDetailAPIEndpoint,
    PageListCreateAPIEndpoint,
)
from plane.api.views.page import (
    PageBulkCreateAPIEndpoint,
    PageVersionDetailAPIEndpoint,
    PageVersionListAPIEndpoint,
)

urlpatterns = [
    path(
        "workspaces/<str:slug>/projects/<uuid:project_id>/pages/",
        PageListCreateAPIEndpoint.as_view(http_method_names=["get", "post"]),
        name="project-pages",
    ),
    # PLN-81: bulk import (before the <uuid:page_id> routes; "bulk" is not a uuid anyway)
    path(
        "workspaces/<str:slug>/projects/<uuid:project_id>/pages/bulk/",
        PageBulkCreateAPIEndpoint.as_view(http_method_names=["post"]),
        name="project-pages-bulk",
    ),
    path(
        "workspaces/<str:slug>/projects/<uuid:project_id>/pages/<uuid:page_id>/",
        PageDetailAPIEndpoint.as_view(http_method_names=["get", "patch"]),
        name="project-page-detail",
    ),
    path(
        "workspaces/<str:slug>/projects/<uuid:project_id>/pages/<uuid:page_id>/archive/",
        PageArchiveAPIEndpoint.as_view(http_method_names=["post", "delete"]),
        name="project-page-archive",
    ),
    # PLN-82: saved versions of a page
    path(
        "workspaces/<str:slug>/projects/<uuid:project_id>/pages/<uuid:page_id>/versions/",
        PageVersionListAPIEndpoint.as_view(http_method_names=["get"]),
        name="project-page-versions",
    ),
    path(
        "workspaces/<str:slug>/projects/<uuid:project_id>/pages/<uuid:page_id>/versions/<uuid:version_id>/",
        PageVersionDetailAPIEndpoint.as_view(http_method_names=["get"]),
        name="project-page-version-detail",
    ),
]
