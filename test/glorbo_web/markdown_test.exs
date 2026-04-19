defmodule GlorboWeb.MarkdownTest do
  @moduledoc """
  Regression suite for the channel markdown pipeline (T-04-13, T-04-18).

  Pipeline order: mention pre-pass → earmark → html_sanitize_ex. Any
  attempt to land `<script>`, `<iframe>`, or `javascript:` URLs in a
  rendered channel message MUST fail sanitization. `@mention` tokens
  MUST be rewritten to an accent-class anchor BEFORE earmark sees the
  body.
  """
  use ExUnit.Case, async: true

  test "strips or escapes <script> tags so they cannot execute" do
    {:safe, html} =
      GlorboWeb.Markdown.render("hello <script>alert(1)</script> world", company: "acme")

    html = IO.iodata_to_binary(html)
    # Live `<script>` must be absent. The literal text may survive as
    # HTML-escaped characters (`&lt;script&gt;`) — that renders as text,
    # not executable JS.
    refute html =~ ~r/<script[\s>]/i
    refute html =~ ~r{</script>}i
    assert html =~ "hello"
  end

  test "rewrites @mention into gl-mention anchor" do
    {:safe, html} = GlorboWeb.Markdown.render("please @ceo review", company: "acme")
    html = IO.iodata_to_binary(html)
    assert html =~ ~s(class="gl-mention")
    assert html =~ "/companies/acme/agents/ceo"
    assert html =~ "@ceo"
  end

  test "renders bold and inline code via earmark" do
    {:safe, html} = GlorboWeb.Markdown.render("**yes** and `code`", company: "acme")
    html = IO.iodata_to_binary(html)
    assert html =~ "<strong>yes</strong>"
    # Earmark tags inline code with class="inline"; sanitizer allows it.
    assert html =~ ~r/<code[^>]*>code<\/code>/
  end

  test "drops javascript: URLs" do
    {:safe, html} = GlorboWeb.Markdown.render("[click](javascript:alert(1))", company: "acme")
    html = IO.iodata_to_binary(html)
    refute html =~ "javascript:"
  end

  test "strips <iframe> tags" do
    {:safe, html} =
      GlorboWeb.Markdown.render("hi <iframe src='/evil'></iframe>", company: "acme")

    html = IO.iodata_to_binary(html)
    refute html =~ "<iframe"
  end

  test "mention regex captures only [a-z0-9-]; bogus HTML in slug escaped" do
    # The regex can only match `@[a-z0-9-]+`; a stray `<` simply terminates
    # the match. Any residual raw HTML is sanitized downstream.
    {:safe, html} = GlorboWeb.Markdown.render("@<script>bad</script>", company: "acme")
    html = IO.iodata_to_binary(html)
    refute html =~ "<script>"
  end

  test "mention inside quoted text still renders as an anchor (UAT W5 regression)" do
    # Earmark used to HTML-escape the `<a>` that the pre-pass emitted
    # when the mention was in a quoted string, e.g. `"@ceo"` in agent
    # replies. The new tokenize-then-detokenize pipeline survives that.
    {:safe, html} =
      GlorboWeb.Markdown.render(~s(message at "@ceo" — are you there?), company: "acme")

    html = IO.iodata_to_binary(html)
    # The <a> tag survives the quote context
    assert html =~ ~s(<a class="gl-mention" href="/companies/acme/agents/ceo">@ceo</a>)
    # No escaped &lt;a tag leakage
    refute html =~ "&lt;a"
  end
end
