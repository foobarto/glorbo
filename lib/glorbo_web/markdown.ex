defmodule GlorboWeb.Markdown do
  @moduledoc """
  Channel message markdown pipeline.

  Four-stage render to defeat XSS (T-04-13) and style `@mention`
  tokens as accent-class anchor links (UI-SPEC §Color accent reserved
  item #5):

    1. **Mention tokenization.** `@slug` → an opaque sentinel string
       Earmark passes through untouched. We can't insert raw `<a>`
       tags here because Earmark re-escapes HTML that sits inside
       markdown text spans (e.g. `"@ceo"` with quotes). UAT-W5 caught
       this: mentions inside quoted-text ended up rendered literally
       as `<a class="...">@slug</a>` because Earmark HTML-escaped the
       brackets. The sentinel `⟦GLMENTION:slug⟧` uses two rare
       code-points that never appear in user text and survive both
       Earmark and the sanitizer.
    2. **Earmark.** `Earmark.as_html!/2` with GFM + `compact_output`
       to render markdown to HTML. Earmark does NOT sanitize — the
       output is untrusted.
    3. **Sanitizer.** `HtmlSanitizeEx.markdown_html/1` strips every
       tag not on its allowlist: `<script>`, `<iframe>`, inline event
       handlers, `javascript:` URLs are all dropped.
    4. **Mention detokenization.** Replace sentinels with the real
       `<a class="gl-mention" href="/companies/:co/agents/:slug">
       @slug</a>`. The slug is HTML-escaped before interpolation
       (T-04-18); the company is escaped once at the top.

  Output is a `{:safe, iodata}` tuple wrapping the sanitized HTML,
  ready for HEEx interpolation (`<div>{body_html}</div>` — the runtime
  renders safe tuples verbatim).
  """

  @mention_re ~r/@([a-z0-9-]+)/
  # Pair of Unicode "mathematical left/right white square brackets"
  # (U+27E6/U+27E7) — not representable via typical keyboard input,
  # so they can't collide with user content. Earmark leaves them as
  # literal text; the sanitizer likewise doesn't touch bracket
  # characters.
  @sentinel_re ~r/⟦GLMENTION:([a-z0-9-]+)⟧/

  @spec render(binary(), keyword()) :: {:safe, iodata()}
  def render(body, opts \\ []) when is_binary(body) do
    company = Keyword.get(opts, :company, "")
    safe_company = company |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    body
    |> tokenize_mentions()
    |> markdown_render()
    |> sanitize()
    |> detokenize_mentions(safe_company)
    |> GlorboWeb.Markdown.Linkify.rewrite(safe_company)
    |> Phoenix.HTML.raw()
  end

  # ---------------------------------------------------------------------------
  # Pipeline stages
  # ---------------------------------------------------------------------------

  defp tokenize_mentions(body) do
    Regex.replace(@mention_re, body, fn _whole, slug -> "⟦GLMENTION:#{slug}⟧" end)
  end

  defp detokenize_mentions(html, safe_company) do
    Regex.replace(@sentinel_re, html, fn _whole, slug ->
      safe_slug = slug |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      ~s(<a class="gl-mention" href="/companies/#{safe_company}/agents/#{safe_slug}">@#{safe_slug}</a>)
    end)
  end

  defp markdown_render(body), do: Glorbo.Markdown.to_html!(body)

  defp sanitize(html), do: HtmlSanitizeEx.markdown_html(html)
end
