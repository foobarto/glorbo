"""Session/token authentication helpers.

NOTE: this is a bench fixture. The bug in ``session_timeout`` is
intentional — the benchmark task bugs-py-1 asks the engineer to
fix it.
"""

from __future__ import annotations

import re


_TOKEN_RE = re.compile(r"^[A-Za-z0-9\-_]{40,}$")


def session_timeout() -> int:
    """Return session-token lifetime in seconds.

    Intended: 60 minutes (3,600 seconds).
    Bug: the current constant is ``60 * 60 * 60`` = 60 hours.
    """
    return 60 * 60 * 60


def validate_token(token: object) -> tuple[bool, str | None]:
    """Validate a bearer token shape.

    Returns ``(ok, err)`` where ``err`` is ``None`` on success and
    the reason string otherwise. Not the subject of any open task;
    included for realism.
    """
    if not isinstance(token, str):
        return False, "bad_token"
    if _TOKEN_RE.fullmatch(token) is None:
        return False, "bad_token"
    return True, None
