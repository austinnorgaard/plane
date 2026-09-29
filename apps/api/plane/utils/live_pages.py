# SPDX-License-Identifier: AGPL-3.0-only
"""Client for the fork endpoints of the live (Hocuspocus) service used by the pages API.

Two calls exist: a presence check (is the page document loaded in the live
service) and a rebase (fold an html change into the stored binary document).
Every failure is reported to the caller as "unknown" or as an error so the
pages API can refuse the write. The shared secret is read from the environment
and is never logged, and neither is any page content.
"""

# Python imports
import logging
import os

# Django imports
from django.conf import settings

# Third party imports
import requests

logger = logging.getLogger("plane.api")

PRESENCE_TIMEOUT_SECONDS = 3
REBASE_TIMEOUT_SECONDS = 10
REBASE_CONTENT_TYPE = "application/vnd.plane-fork.rebase+json"


class LiveServiceError(Exception):
    """The live service could not be reached or answered with something unusable."""


def _base_url():
    live_url = getattr(settings, "LIVE_URL", None)
    if not live_url:
        return None
    return live_url if live_url.endswith("/") else live_url + "/"


def _secret_header():
    return {"live-server-secret-key": os.environ.get("LIVE_SERVER_SECRET_KEY", "")}


def is_page_loaded(page_id):
    """Return True if the page is loaded in the live service, False if it is not,
    and None if that cannot be determined (no live url, timeout, bad answer)."""
    base = _base_url()
    if base is None:
        return None
    try:
        response = requests.get(
            f"{base}fork/pages/{page_id}/loaded",
            headers=_secret_header(),
            timeout=PRESENCE_TIMEOUT_SECONDS,
        )
        if response.status_code != 200:
            return None
        loaded = response.json().get("loaded")
    except (requests.RequestException, ValueError, AttributeError) as exc:
        logger.warning("live presence check failed for page %s (%s)", page_id, type(exc).__name__)
        return None
    return loaded if isinstance(loaded, bool) else None


def rebase_page(page_id, description_binary_b64, description_html):
    """Ask the live service to apply description_html on top of the stored binary
    document. Returns the decoded json answer. Raises LiveServiceError on any failure."""
    base = _base_url()
    if base is None:
        raise LiveServiceError("live url is not configured")
    try:
        response = requests.post(
            f"{base}fork/pages/rebase",
            json={
                "page_id": str(page_id),
                "description_binary": description_binary_b64,
                "description_html": description_html,
            },
            headers={**_secret_header(), "Content-Type": REBASE_CONTENT_TYPE},
            timeout=REBASE_TIMEOUT_SECONDS,
        )
        if response.status_code != 200:
            raise LiveServiceError(f"rebase answered {response.status_code}")
        result = response.json()
    except (requests.RequestException, ValueError) as exc:
        logger.warning("live rebase failed for page %s (%s)", page_id, type(exc).__name__)
        raise LiveServiceError("rebase call failed") from exc
    if not isinstance(result, dict):
        raise LiveServiceError("rebase answer is not an object")
    return result
