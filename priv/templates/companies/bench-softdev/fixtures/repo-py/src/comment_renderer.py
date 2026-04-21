"""Render user comments to HTML.

bench task bugs-py-3 asks the engineer to plug the XSS hole —
``render()`` currently emits raw HTML and the task body must be
escaped.

NOTE: intentionally vulnerable. Do not copy this module into
production code — it is a bench fixture.
"""

from __future__ import annotations

from typing import Mapping


def render(comment: Mapping[str, str]) -> str:
    body = comment["body"]
    author = comment["author"]
    return f"<article><header>@{author}</header><section>{body}</section></article>"


def wrap_link(url: str, text: str) -> tuple[str, str]:
    """Wrap a URL into an ``<a href>`` link.

    Callers pre-compute this; the sanitizer added by bugs-py-3
    must preserve these links.
    """
    return ("safe", f'<a href="{url}">{text}</a>')
