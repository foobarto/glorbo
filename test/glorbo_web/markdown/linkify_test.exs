defmodule GlorboWeb.Markdown.LinkifyTest do
  use ExUnit.Case, async: true

  alias GlorboWeb.Markdown.Linkify

  describe "rewrite/2" do
    test "links a bare task-id inside paragraph text" do
      html = "<p>Blocked on blueprints-01 — reassigning.</p>"
      result = Linkify.rewrite(html, "acme")

      assert result =~ ~s(<a class="gl-task-ref")
      assert result =~ "/companies/acme/kanban?task=projects/blueprints/tasks/blueprints-01.md"
      # The original visible token is preserved.
      assert result =~ ">blueprints-01</a>"
    end

    test "does not double-wrap task-ids already inside tags" do
      # e.g. a reply preview that's already a plain string — but the
      # pass runs after sanitize, so inputs won't typically have
      # pre-linked refs. The regex must still not match inside
      # attribute values.
      html = ~s(<a href="/x?task=blueprints-01.md">other</a>)
      result = Linkify.rewrite(html, "acme")

      # The href attribute value (task=blueprints-01.md) must NOT be
      # rewritten — only text nodes get the linkifier.
      assert result == html
    end

    test "leaves numeric-only and YYYY-MM tokens alone" do
      html = "<p>Audit month 2026-04 has 12 events.</p>"
      result = Linkify.rewrite(html, "acme")

      # 2026-04 is a digit-only prefix → first char isn't a-z → no match.
      refute result =~ "gl-task-ref"
      # '12' has no prefix → no match.
      refute result =~ "/tasks/12"
    end

    test "handles multiple refs in the same text node" do
      html = "<p>See blueprints-01 and web-3 for context.</p>"
      result = Linkify.rewrite(html, "acme")

      assert result =~ "projects/blueprints/tasks/blueprints-01.md"
      assert result =~ "projects/web/tasks/web-3.md"
    end

    test "escapes the task-id text when rendering the anchor body" do
      # The regex tokenizer only matches safe shapes, but belt-and-
      # braces: the visible body is HTML-escaped before interpolation.
      html = "<p>blueprints-01</p>"
      assert Linkify.rewrite(html, "acme") =~ ">blueprints-01</a>"
    end

    test "compound project slugs (with dashes) are preserved in the path" do
      html = "<p>See web-redesign-42 today.</p>"
      result = Linkify.rewrite(html, "acme")

      assert result =~ "projects/web-redesign/tasks/web-redesign-42.md"
    end
  end
end
