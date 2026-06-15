defmodule Glorbo.ChannelLog do
  @moduledoc """
  Canonical channel-log message format and parser.

  On-disk shape (GEP-30 / UI-SPEC):

      ## <iso-ts> | <author> ::<provenance>
      <body>

  `provenance` is stamped only by trusted writers (`Glorbo.Actions`,
  `Glorbo.Company.Router`) so the UI can render director/system badges
  from authenticated identity — not from re-parsed markdown text an agent
  could embed in a message body (codex L45).

  Legacy posts without the ` ::provenance` suffix still parse; provenance
  falls back to the author slug for backward compatibility.
  """

  @message_re ~r/^## (?<ts>\d{4}-\d{2}-\d{2}[^|]*?)\s*\|\s*(?<author>.+?)\s*\n(?<body>.*?)(?=\n## \d{4}-|\z)/ms

  @provenance_suffix_re ~r/ ::(?<kind>director|agent|system)\z/

  # Lines that look like a channel-log header — agents must not inject these
  # into message bodies or the tail parser will split them into forged posts.
  @header_line_re ~r/^## \d{4}-\d{2}-\d{2}/

  @type provenance :: :director | :agent | :system

  @doc """
  Append a channel-log block. Agent posts sanitize header-like lines in the
  body; director/system posts are trusted and pass the body through.
  """
  @spec format_post(String.t(), String.t(), provenance()) :: String.t()
  def format_post(author, body, provenance) when provenance in [:director, :agent, :system] do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    prov = Atom.to_string(provenance)

    body =
      case provenance do
        :agent -> sanitize_agent_body(body)
        _ -> body
      end

    "\n## #{ts} | #{author} ::#{prov}\n#{String.trim(body)}\n"
  end

  @doc """
  Neutralize header-shaped lines in agent-authored bodies so they cannot
  be re-parsed as top-level channel messages.
  """
  @spec sanitize_agent_body(String.t()) :: String.t()
  def sanitize_agent_body(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if Regex.match?(@header_line_re, line), do: "> #{line}", else: line
    end)
  end

  @doc """
  Parse channel-log tail content into message maps:

      %{author: ..., provenance: :director | :agent | :system, timestamp: ..., body: ...}

  `body` is raw markdown; callers render HTML.
  """
  @spec parse_messages(String.t()) :: [map()]
  def parse_messages(content) when is_binary(content) do
    @message_re
    |> Regex.scan(content, capture: :all_names)
    |> Enum.map(fn [author_raw, body, ts] ->
      {author, provenance} = parse_author_provenance(String.trim(author_raw))

      %{
        author: author,
        provenance: provenance,
        timestamp: String.trim(ts),
        body: String.trim(body)
      }
    end)
    |> Enum.take(-200)
  end

  defp parse_author_provenance(author_raw) do
    case Regex.named_captures(@provenance_suffix_re, author_raw) do
      %{"kind" => kind} ->
        base = String.replace_suffix(author_raw, " ::" <> kind, "")
        {base, String.to_existing_atom(kind)}

      nil ->
        {author_raw, provenance_from_author_slug(author_raw)}
    end
  end

  defp provenance_from_author_slug(author) do
    case String.downcase(author) do
      "director" -> :director
      "system" -> :system
      _ -> :agent
    end
  end
end
