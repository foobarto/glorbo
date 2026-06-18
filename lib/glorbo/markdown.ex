defmodule Glorbo.Markdown do
  @moduledoc """
  Shared markdown → HTML rendering for untrusted text.

  Uses MDEx + GFM (replaces retired `earmark`). Output is **not** sanitized —
  callers must run `HtmlSanitizeEx.markdown_html/1` before embedding in HTML.
  """

  @doc """
  Render `body` markdown to an HTML fragment string (GFM).
  """
  @spec to_html!(binary()) :: binary()
  def to_html!(body) when is_binary(body) do
    MDEx.to_html!(body, plugins: [MDExGFM])
  end
end
