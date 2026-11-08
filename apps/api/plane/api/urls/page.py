# SPDX-License-Identifier: AGPL-3.0-only

from django.urls import path

from plane.api.views import (
    PageArchiveAPIEndpoint,
    PageDetailAPIEndpoint,
    PageListCreateAPIEndpoint,
)

urlpatterns = [
    path(
        "workspaces/<str:slug>/projects/<uuid:project_id>/pages/",
        PageListCreateAPIEndpoint.as_view(http_method_names=["get", "post"]),
        name="project-pages",
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
]
