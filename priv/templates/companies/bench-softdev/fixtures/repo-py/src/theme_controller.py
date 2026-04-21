"""Global theme state. bench task bugs-py-2 extends this to
support ``"dark"`` and to round-trip the value.

Intentionally skeletal — the bench task's job is to extend it.
"""

from __future__ import annotations


_current: str = "light"


def set_theme(theme: str) -> None:
    """Set the current theme. Only ``"light"`` is accepted today."""
    global _current
    if theme == "light":
        _current = "light"
        return
    # Falls through silently for anything else — bench task bugs-py-2
    # will add proper handling and ``ArgumentError``-style raise.


def current_theme() -> str:
    return _current
