defmodule GlorboWeb.Markdown do
  @moduledoc """
  Channel message markdown pipeline.

  Three-stage render to defeat XSS (T-04-13) and style `@mention`
  tokens as accent-class anchor links (UI-SPEC §Color accent reserved
  item #5):

    1. **Mention pre-pass.** `@slug` → `<a class="gl-mention"
       href="/companies/:co/agents/:slug">@slug</a>`. The regex is
       `~r/@([a-z0-9-]+)/` — only ASCII-lowercase slug chars are
       captured; a stray `<` terminates the match. The captured slug
       is HTML-escaped via `Phoenix.HTML.html_escape/1` before being
       interpolated into the anchor template (T-04-18).
    2. **Earmark.** `Earmark.as_html!/2` with GFM + `compact_output`
       to render markdown to HTML. Earmark does NOT sanitize — the
       output is untrusted.
    3. **Sanitizer.** `HtmlSanitizeEx.markdown_html/1` strips every
       tag not on its allowlist: `<script>`, `<iframe>`, inline event
       handlers, `javascript:` URLs are all dropped.

  Output is a `{:safe, iodata}` tuple wrapping the sanitized HTML,
  ready for HEEx interpolation (`<div>{body_html}</div>` — the runtime
  renders safe tuples verbatim).
  """

  @mention_re ~r/@([a-z0-9-]+)/

  @spec render(binary(), keyword()) :: {:safe, iodata()}
  def render(body, opts \\ []) when is_binary(body) do
    company = Keyword.get(opts, :company, "")
    safe_company = company |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    body
    |> mention_pre_pass(safe_company)
    |> earmark_render()
    |> sanitize()
    |> Phoenix.HTML.raw()
  end

  # ---------------------------------------------------------------------------
  # Pipeline stages
  # ---------------------------------------------------------------------------

  defp mention_pre_pass(body, safe_company) do
    Regex.replace(@mention_re, body, fn _whole, slug ->
      safe_slug = slug |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      ~s(<a class="gl-mention" href="/companies/#{safe_company}/agents/#{safe_slug}">@#{safe_slug}</a>)
    end)
  end

  defp earmark_render(body) do
    Earmark.as_html!(body, %Earmark.Options{compact_output: true, smartypants: false, gfm: true})
  end

  defp sanitize(html), do: HtmlSanitizeEx.markdown_html(html)
end
