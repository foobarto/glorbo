defmodule GlorboWeb.SearchController do
  @moduledoc """
  JSON search endpoint consumed by the Ctrl+K palette (#232 T2-B).

  `GET /api/search?co=<slug>&q=<query>&limit=20` →
    %{results: [%{kind, label, href, score}, ...]}

  Validates slug + query, caps limit at 50, returns `[]` on any
  invalid input rather than 400 — the palette calls this on every
  keystroke and noisy errors would spam the console.
  """
  use GlorboWeb, :controller

  @max_limit 50
  @max_query_len 200

  def search(conn, params) do
    results =
      with {:ok, co} <- fetch_slug(params),
           {:ok, q} <- fetch_query(params),
           limit <- fetch_limit(params) do
        Glorbo.Search.search(base_dir(), co, q, limit: limit)
      else
        _ -> []
      end

    json(conn, %{results: results})
  end

  defp fetch_slug(%{"co" => co}) do
    if Glorbo.Slug.valid?(co), do: {:ok, co}, else: :error
  end

  defp fetch_slug(_), do: :error

  defp fetch_query(%{"q" => q}) when is_binary(q) do
    trimmed = String.trim(q)

    cond do
      trimmed == "" -> :error
      String.length(trimmed) > @max_query_len -> :error
      true -> {:ok, trimmed}
    end
  end

  defp fetch_query(_), do: :error

  defp fetch_limit(%{"limit" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> min(n, @max_limit)
      _ -> 20
    end
  end

  defp fetch_limit(_), do: 20

  defp base_dir, do: Glorbo.Filesystem.Hierarchy.default_root()
end
