# SPDX-License-Identifier: AGPL-3.0-only

"""OpenAPI parameters and responses specific to the project pages endpoints."""

from drf_spectacular.types import OpenApiTypes
from drf_spectacular.utils import OpenApiExample, OpenApiParameter, OpenApiResponse

PAGE_ID_PARAMETER = OpenApiParameter(
    name="page_id",
    description="Page ID",
    required=True,
    type=OpenApiTypes.UUID,
    location=OpenApiParameter.PATH,
)

PAGE_ARCHIVED_PARAMETER = OpenApiParameter(
    name="archived",
    description="Return archived pages instead of active ones (default: false)",
    required=False,
    type=OpenApiTypes.BOOL,
    location=OpenApiParameter.QUERY,
)

PAGE_PARENT_ID_PARAMETER = OpenApiParameter(
    name="parent_id",
    description="Return only the direct children of this page",
    required=False,
    type=OpenApiTypes.UUID,
    location=OpenApiParameter.QUERY,
)

PAGE_ORDER_BY_PARAMETER = OpenApiParameter(
    name="order_by",
    description=(
        "Field to order by; prefix with '-' for descending order. "
        "Allowed: created_at, updated_at, name, sort_order (default: -created_at)"
    ),
    required=False,
    type=OpenApiTypes.STR,
    location=OpenApiParameter.QUERY,
)


def _example(name, value):
    return OpenApiExample(name=name, value=value)


PAGE_BAD_REQUEST_RESPONSE_DESCRIPTION = (
    "The request is invalid: a malformed body, an unknown or missing field, a locked or archived page, "
    "pages disabled for the project, or an invalid pagination parameter."
)

PAGE_VALIDATION_EXAMPLES = [
    _example("Pages disabled", {"error": "Pages are disabled for this project"}),
    _example("Unsupported field", {"non_field_errors": ["Unsupported field(s): color"]}),
    _example("Locked page", {"error": "Page is locked"}),
]

PAGE_CONFLICT_CREATE_RESPONSE = OpenApiResponse(
    description=(
        "A page with the same external_id and external_source already exists in the project; "
        "the body carries the id of the existing page."
    ),
    examples=[
        _example(
            "Duplicate external id",
            {
                "error": "Page with the same external id and external source already exists",
                "id": "550e8400-e29b-41d4-a716-446655440000",
            },
        )
    ],
)

PAGE_CONFLICT_UPDATE_RESPONSE = OpenApiResponse(
    description=(
        "The page is open in an editor, so it cannot be updated now. Retry later; "
        "if the response carries a Retry-After header, wait at least that long."
    ),
    examples=[_example("Open in editor", {"error": "page is open in an editor; retry later"})],
)

PAGE_TOO_LARGE_RESPONSE = OpenApiResponse(
    description=(
        "The request body or description_html is too large. When the description_html cap was exceeded "
        "the body carries max_bytes. Not retryable without shrinking the content."
    ),
    examples=[
        _example("HTML too large", {"error": "description_html too large", "max_bytes": 262144}),
        _example("Body too large", {"error": "request body too large"}),
    ],
)

PAGE_LIVE_UNAVAILABLE_RESPONSE = OpenApiResponse(
    description="The live collaboration service is unavailable; the page was not updated. Retry later.",
    examples=[_example("Live unavailable", {"error": "live service unavailable, page not updated"})],
)
