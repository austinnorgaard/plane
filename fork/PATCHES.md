<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Upstream files patched by the fork

One line per touched upstream file: ticket id and the reason.

- `apps/api/plane/api/urls/__init__.py` - PLN-8: include the project pages routes.
- `apps/api/plane/api/views/__init__.py` - PLN-8: export the project pages endpoints.
- `apps/api/plane/api/serializers/__init__.py` - PLN-8: export the project pages serializers.
- `apps/api/plane/bgtasks/page_version_task.py` - PLN-8: read `page.description_json` instead of the non-existent `page.description` (unconditional fix, two lines).
