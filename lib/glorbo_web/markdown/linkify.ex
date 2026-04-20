defmodule GlorboWeb.Markdown.Linkify do
  @moduledoc """
  Post-sanitizer pass that converts Glorbo task-id tokens into
  clickable anchor tags.

  Tokens: `<project-slug>-<digits>` — e.g. `blueprints-01`, `web-3`.
  The project slug is the prefix before the final `-NN`; the kanban
  view exposes a deep-link query param `?task=projects/<project>/tasks/<task-id>.md`
  that opens the task overlay directly.

  Implemented as its own module (parallel to the mention detokenizer
  in `GlorboWeb.Markdown`) so non-channel contexts — task bodies,
  comments, audit entries — can call into it without pulling in the
  full Earmark + sentinel pipeline.

  ## Why post-sanitizer

  Running after Earmark + HtmlSanitizeEx means the input is already a
  safe HTML string. We only substitute inside *text* nodes — never
  inside attributes or tag bodies — via a simple "outside-tags"
  tokenizer. Slugs are HTML-escaped before interpolation (T-04-18).
  """

  # Tight shape: lowercase letters + digits in the prefix, allowing
  # embedded dashes *except* immediately before the trailing digits
  # (otherwise `foo--1` would match). Minimum one prefix letter so
  # pure numeric strings like `2026-04` (audit month buckets) don't
  # trip.
  @task_id_re ~r/\b([a-z][a-z0-9_]*(?:-[a-z0-9_]+)*)-(\d+)\b/

  @doc """
  Rewrite every bare task-id token in `html` into an anchor tag
  pointing at the kanban task-detail deep link for `company`.

  `company` is HTML-escaped by the caller (the mention pipeline
  already does this); if you're calling this in a new context, pass
  a `Phoenix.HTML.html_escape |> safe_to_string` result.
  """
  @spec rewrite(String.t(), String.t()) :: String.t()
  def rewrite(html, company) when is_binary(html) and is_binary(company) do
    html
    |> split_on_tags()
    |> Enum.map(fn
      {:tag, segment} -> segment
      {:text, segment} -> linkify_text(segment, company)
    end)
    |> IO.iodata_to_binary()
  end

  # Split on `<…>` boundaries so we only substitute inside text
  # nodes. The HTML arriving here is already sanitized so tag nesting
  # is well-formed.
  defp split_on_tags(html) do
    ~r/<[^>]*>/
    |> Regex.split(html, include_captures: true)
    |> Enum.map(fn
      "<" <> _ = tag -> {:tag, tag}
      text -> {:text, text}
    end)
  end

  defp linkify_text("", _company), do: ""

  defp linkify_text(text, company) do
    Regex.replace(@task_id_re, text, fn whole, prefix, num ->
      safe_prefix = html_escape(prefix)
      safe_num = html_escape(num)
      task_id = "#{safe_prefix}-#{safe_num}"

      ~s(<a class="gl-task-ref" href="/companies/#{company}/kanban?task=projects/#{safe_prefix}/tasks/#{task_id}.md">#{whole}</a>)
    end)
  end

  defp html_escape(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
