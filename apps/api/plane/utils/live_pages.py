# SPDX-License-Identifier: AGPL-3.0-only
"""Client for the fork endpoints of the live (Hocuspocus) service used by the pages API.

Calls: a presence check (is the page document loaded in the live service), a
rebase (fold an html change into the stored binary document), and the document
write lock (PLN-98: taken right before the database commit of a PATCH, so no
editor can load the page until the write is committed).
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
LOCK_TIMEOUT_SECONDS = 3
WRITE_LOCK_TOKEN_HEADER = "x-fork-write-lock-token"

# acquire_write_lock outcomes
LOCK_ACQUIRED = "acquired"
LOCK_LOADED = "loaded"  # the page is open in an editor
LOCK_BUSY = "busy"  # another api write holds the lock
LOCK_UNSUPPORTED = "unsupported"  # live predates PLN-98 (no lock route): fall back to the presence check
LOCK_UNKNOWN = "unknown"  # live unreachable or a bad answer


class LiveServiceError(Exception):
    """The live service could not be reached or answered with something unusable.

    too_large is True when live refused the content as too large (its own size cap): that is not
    retryable, so the pages API answers 413 instead of 503."""

    too_large = False


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


def rebase_page(page_id, base_binary_b64, description_html, name):
    """Ask the live service to apply description_html and/or name (either may be None)
    on top of the stored binary document. Returns the decoded json answer.
    Raises LiveServiceError on any failure."""
    base = _base_url()
    if base is None:
        raise LiveServiceError("live url is not configured")
    try:
        response = requests.post(
            f"{base}fork/pages/rebase",
            json={
                "base_binary": base_binary_b64,
                "description_html": description_html,
                "name": name,
            },
            headers={**_secret_header(), "Content-Type": REBASE_CONTENT_TYPE},
            timeout=REBASE_TIMEOUT_SECONDS,
        )
        if response.status_code == 413:
            error = LiveServiceError("rebase answered 413")
            error.too_large = True
            raise error
        if response.status_code != 200:
            raise LiveServiceError(f"rebase answered {response.status_code}")
        result = response.json()
    except (requests.RequestException, ValueError) as exc:
        logger.warning("live rebase failed for page %s (%s)", page_id, type(exc).__name__)
        raise LiveServiceError("rebase call failed") from exc
    if not isinstance(result, dict):
        raise LiveServiceError("rebase answer is not an object")
    return result


def acquire_write_lock(page_id):
    """Take the live document write lock for the page (PLN-98).

    Returns (outcome, token): token is set only for LOCK_ACQUIRED. Live grants the lock only while the
    page is not loaded, and holds back any new load of the page until release_write_lock (or its TTL)."""
    base = _base_url()
    if base is None:
        return LOCK_UNKNOWN, None
    try:
        response = requests.post(
            f"{base}fork/pages/{page_id}/write-lock",
            headers=_secret_header(),
            timeout=LOCK_TIMEOUT_SECONDS,
            allow_redirects=False,
        )
        if response.status_code == 404:
            return LOCK_UNSUPPORTED, None
        if response.status_code != 200:
            return LOCK_UNKNOWN, None
        body = response.json()
    except (requests.RequestException, ValueError) as exc:
        logger.warning("live write lock failed for page %s (%s)", page_id, type(exc).__name__)
        return LOCK_UNKNOWN, None
    if not isinstance(body, dict):
        return LOCK_UNKNOWN, None
    if body.get("acquired") is True and isinstance(body.get("token"), str):
        return LOCK_ACQUIRED, body["token"]
    if body.get("reason") == "loaded":
        return LOCK_LOADED, None
    if body.get("reason") == "busy":
        return LOCK_BUSY, None
    return LOCK_UNKNOWN, None


def release_write_lock(page_id, token):
    """Release the lock (best effort; it expires on its own). Returns True when live released it."""
    base = _base_url()
    if base is None or not token:
        return False
    try:
        response = requests.delete(
            f"{base}fork/pages/{page_id}/write-lock",
            headers={**_secret_header(), WRITE_LOCK_TOKEN_HEADER: token},
            timeout=LOCK_TIMEOUT_SECONDS,
            allow_redirects=False,
        )
    except requests.RequestException as exc:
        logger.warning("live write unlock failed for page %s (%s)", page_id, type(exc).__name__)
        return False
    if response.status_code == 404:
        # the lock had expired before the commit finished: an editor may have loaded the old state
        logger.warning("live write lock for page %s expired before it was released", page_id)
        return False
    return response.status_code == 204
