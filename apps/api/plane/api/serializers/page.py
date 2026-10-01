# SPDX-License-Identifier: AGPL-3.0-only

# Third party imports
from rest_framework import serializers

# Module imports
from plane.db.models import Page, ProjectPage
from plane.utils.content_validator import validate_html_content

EMPTY_HTML = "<p></p>"
PATCHABLE_FIELDS = ("name", "description_html")


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
    name = serializers.CharField(required=False, allow_blank=True, default="")
    description_html = serializers.CharField(required=False, allow_blank=True, allow_null=True, default=EMPTY_HTML)
    access = serializers.ChoiceField(choices=[0, 1], required=False, default=0)
    color = serializers.CharField(required=False, allow_blank=True, max_length=255, default="")
    parent = serializers.UUIDField(required=False, allow_null=True, default=None)
    external_id = serializers.CharField(required=False, allow_null=True, allow_blank=True, max_length=255, default=None)
    external_source = serializers.CharField(
        required=False, allow_null=True, allow_blank=True, max_length=255, default=None
    )

    def validate_description_html(self, value):
        return clean_description_html(value)

    def validate_parent(self, value):
        """The parent must be an active page of the project in the url."""
        if value is None:
            return None
        project = self.context["project"]
        linked = ProjectPage.objects.filter(
            page_id=value,
            project_id=project.id,
            workspace_id=project.workspace_id,
            deleted_at__isnull=True,
        ).exists()
        if not linked:
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

    name = serializers.CharField(required=False, allow_blank=True)
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
