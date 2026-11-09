# SPDX-License-Identifier: AGPL-3.0-only

# Third party imports
import nh3
from rest_framework import serializers

# Module imports
from plane.db.models import Page, PageVersion, ProjectPage
from plane.utils.content_validator import ALLOWED_TAGS, ATTRIBUTES, SAFE_PROTOCOLS, validate_html_content
from plane.utils.openapi.pages import PAGE_ACCESS_CHOICES

EMPTY_HTML = "<p></p>"
PATCHABLE_FIELDS = ("name", "description_html")
# PLN-99 (review F11): the model field is unbounded; the API caps the title.
MAX_NAME_LENGTH = 255


def clean_description_html(value):
    """Sanitize client html and return the cleaned value; empty becomes '<p></p>'."""
    if not value:
        return EMPTY_HTML
    is_valid, error_message, clean_html = validate_html_content(value)
    if not is_valid:
        raise serializers.ValidationError(error_message)
    clean_html = clean_html if clean_html is not None else value
    return clean_html or EMPTY_HTML


class PageAPISerializer(serializers.ModelSerializer):
    """Read shape of a project page."""

    project_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = Page
        fields = [
            "id",
            "name",
            "description_html",
            "access",
            "color",
            "parent",
            "owned_by",
            "is_locked",
            "archived_at",
            "external_id",
            "external_source",
            "project_id",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields


class PageListAPISerializer(PageAPISerializer):
    """List shape: same as detail without the (possibly large) html body."""

    class Meta(PageAPISerializer.Meta):
        fields = [f for f in PageAPISerializer.Meta.fields if f != "description_html"]
        read_only_fields = fields


class PageCreateAPISerializer(serializers.Serializer):
    name = serializers.CharField(required=False, allow_blank=True, max_length=MAX_NAME_LENGTH, default="")
    description_html = serializers.CharField(required=False, allow_blank=True, allow_null=True, default=EMPTY_HTML)
    access = serializers.ChoiceField(choices=PAGE_ACCESS_CHOICES, required=False, default=0)
    color = serializers.CharField(required=False, allow_blank=True, max_length=255, default="")
    parent = serializers.UUIDField(required=False, allow_null=True, default=None)
    external_id = serializers.CharField(required=False, allow_null=True, allow_blank=True, max_length=255, default=None)
    external_source = serializers.CharField(
        required=False, allow_null=True, allow_blank=True, max_length=255, default=None
    )

    def validate_description_html(self, value):
        return clean_description_html(value)

    def validate_parent(self, value):
        """The parent must be a page of the project in the url that the caller can see and that is not
        archived (PLN-99, review F6). Hidden, unknown and archived parents get the same answer, so the
        error is not an existence oracle for other users' private pages."""
        if value is None:
            return None
        visible = self.context.get("visible_pages")
        if visible is not None:
            ok = visible.filter(pk=value, archived_at__isnull=True).exists()
        else:
            project = self.context["project"]
            ok = ProjectPage.objects.filter(
                page_id=value,
                project_id=project.id,
                workspace_id=project.workspace_id,
                deleted_at__isnull=True,
                page__archived_at__isnull=True,
            ).exists()
        if not ok:
            raise serializers.ValidationError("Parent page does not belong to this project.")
        return value

    def validate(self, attrs):
        if not attrs.get("external_id"):
            attrs["external_id"] = None
        if not attrs.get("external_source"):
            attrs["external_source"] = None
        return attrs


class PageUpdateAPISerializer(serializers.Serializer):
    """PATCH accepts exactly name and description_html; any other key is a 400."""

    name = serializers.CharField(required=False, allow_blank=True, max_length=MAX_NAME_LENGTH)
    description_html = serializers.CharField(required=False, allow_blank=True)

    def validate(self, attrs):
        unknown = set(self.initial_data.keys()) - set(PATCHABLE_FIELDS)
        if unknown:
            raise serializers.ValidationError(f"Unsupported field(s): {', '.join(sorted(unknown))}")
        if not attrs:
            raise serializers.ValidationError("Provide name and/or description_html.")
        return attrs

    def validate_description_html(self, value):
        return clean_description_html(value)


def sanitize_output_html(value):
    """Sanitise stored html on the way out (PLN-82): the same nh3 rules as on write, without the removal
    log of validate_html_content (a read must not let callers inflate the log). Stored versions were
    written by several paths, so the read does not trust them."""
    if not value:
        return EMPTY_HTML
    try:
        return nh3.clean(value, tags=ALLOWED_TAGS, attributes=ATTRIBUTES, url_schemes=SAFE_PROTOCOLS) or EMPTY_HTML
    except Exception:
        return EMPTY_HTML


class PageVersionAPISerializer(serializers.ModelSerializer):
    """List shape of a page version (PLN-82): metadata only, no content."""

    page_id = serializers.UUIDField(read_only=True)
    owned_by_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = PageVersion
        fields = ["id", "page_id", "last_saved_at", "owned_by_id", "created_at", "updated_at"]
        read_only_fields = fields


class PageVersionDetailAPISerializer(PageVersionAPISerializer):
    """One page version with its html, sanitised on output. The binary and json forms are not exposed."""

    description_html = serializers.SerializerMethodField()

    class Meta(PageVersionAPISerializer.Meta):
        fields = [*PageVersionAPISerializer.Meta.fields, "description_html"]
        read_only_fields = fields

    def get_description_html(self, obj) -> str:
        return sanitize_output_html(obj.description_html)


class PageBulkCreateAPISerializer(serializers.Serializer):
    """Documentation shape of the bulk import body (PLN-81); items are validated one by one in the view."""

    pages = PageCreateAPISerializer(many=True)


class PageBulkItemResultAPISerializer(serializers.Serializer):
    """One item of a bulk import answer: created (with the page) or conflict (with the error, and the id of
    the existing page when the caller can see it)."""

    index = serializers.IntegerField()
    status = serializers.ChoiceField(choices=["created", "conflict"])
    page = PageAPISerializer(required=False)
    error = serializers.CharField(required=False)
    id = serializers.UUIDField(required=False)


class PageBulkResultAPISerializer(serializers.Serializer):
    created = serializers.IntegerField()
    conflicts = serializers.IntegerField()
    results = PageBulkItemResultAPISerializer(many=True)


class PageBulkErrorAPISerializer(serializers.Serializer):
    """Documentation shape of a bulk import 400: a body error, or the invalid items with their index."""

    error = serializers.CharField(required=False)
    max_pages = serializers.IntegerField(required=False)
    errors = serializers.ListField(child=serializers.DictField(), required=False)


class PageErrorAPISerializer(serializers.Serializer):
    """Documentation shape of an error body (400, 403, 413 without a limit, 503)."""

    error = serializers.CharField()


class PageValidationErrorAPISerializer(serializers.Serializer):
    """Documentation shape of a 400 body: either an error message or field errors keyed by field name."""

    error = serializers.CharField(required=False)
    name = serializers.ListField(child=serializers.CharField(), required=False)
    description_html = serializers.ListField(child=serializers.CharField(), required=False)
    non_field_errors = serializers.ListField(child=serializers.CharField(), required=False)


class PageListErrorAPISerializer(serializers.Serializer):
    """Documentation shape of a 400 body from the list endpoint (invalid pagination parameter)."""

    detail = serializers.CharField()


class PageConflictAPISerializer(serializers.Serializer):
    """Documentation shape of a 409 body; id is present only for a duplicate external id."""

    error = serializers.CharField()
    id = serializers.UUIDField(required=False)


class PageTooLargeAPISerializer(serializers.Serializer):
    """Documentation shape of a 413 body; max_bytes is present when the description_html cap was exceeded."""

    error = serializers.CharField()
    max_bytes = serializers.IntegerField(required=False)


class PageArchiveResultAPISerializer(serializers.Serializer):
    """Documentation shape of the archive response."""

    archived_at = serializers.DateField()
