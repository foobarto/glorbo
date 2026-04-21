"""Regression tests for ``comment_renderer``.

Engineer adding bugs-py-3 (XSS sanitizer) should insert a test
that ``render({"body": "<script>alert(1)</script>", "author":
"mal"})`` escapes the script tag.
"""
