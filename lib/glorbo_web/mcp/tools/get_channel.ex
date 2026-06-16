defmodule GlorboWeb.MCP.Tools.GetChannel do
  @moduledoc """
  MCP tool: `glorbo.get_channel` (GEP-29 wave b.2).

  Reads a channel markdown file and returns its message stream.
  Messages are append-only entries shaped as
  `## <iso-timestamp> | <author>\n<body>`; this tool re-parses the
  same format `ChannelLive` uses for the dashboard.

  Optional `since` (ISO8601) and `limit` narrow the output. Body is
  returned as raw markdown — MCP clients render their own way.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.ChannelLog
  alias GlorboWeb.MCP.Args

  # Parsed via `Glorbo.ChannelLog` (provenance suffix + sanitization).

  @impl true
  def name, do: "glorbo.get_channel"

  @impl true
  def description,
    do: """
    Fetch messages from a chat channel. Returns a list of
    `{timestamp, author, body}` entries newest-first. `since`
    filters to messages strictly after the given ISO8601 timestamp.
    `limit` caps the count (default 50; max 500).
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "channel" => %{"type" => "string"},
        "since" => %{"type" => ["string", "null"], "description" => "ISO8601 timestamp"},
        "limit" => %{"type" => ["integer", "null"]}
      },
      "required" => ["company", "channel"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company, "channel" => channel} = args, context)
      when is_binary(company) and is_binary(channel) do
    with :ok <- Args.require_slugs(company: company, channel: channel) do
      do_call(company, channel, args, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, channel, args, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    path = Path.join([base, "companies", company, "channels", "#{channel}.md"])

    # Threatmodel wave 25: agent-RW channel md. 5 MiB cap is
    # generous (rotation kicks in much earlier in practice); prevents
    # a runaway write OOM-ing MCP clients reading the channel.
    case Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 5_242_880) do
      {:ok, content} ->
        messages =
          content
          |> ChannelLog.parse_messages()
          |> Enum.map(&to_entry/1)
          |> maybe_filter_since(nilify(args["since"]))
          |> Enum.reverse()
          |> Enum.take(clamp_limit(args["limit"]))

        {:ok, %{"messages" => messages}}

      {:error, :enoent} ->
        {:error, {:channel_not_found, channel}}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp to_entry(%{author: author, body: body, timestamp: ts, provenance: prov}) do
    %{
      "timestamp" => ts,
      "author" => author,
      "provenance" => Atom.to_string(prov),
      "body" => String.trim_trailing(body)
    }
  end

  defp maybe_filter_since(messages, nil), do: messages

  defp maybe_filter_since(messages, since) do
    # Compare via DateTime.compare so fractional-second precision
    # mismatches don't drop boundary messages. Malformed timestamps
    # on either side fall back to permissive-include.
    case parse_iso(since) do
      nil ->
        messages

      since_dt ->
        Enum.filter(messages, fn m ->
          case parse_iso(m["timestamp"]) do
            nil -> true
            ts -> DateTime.compare(ts, since_dt) == :gt
          end
        end)
    end
  end

  defp parse_iso(nil), do: nil
  defp parse_iso(""), do: nil

  defp parse_iso(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_iso(_), do: nil

  defp clamp_limit(nil), do: 50
  defp clamp_limit(n) when is_integer(n) and n >= 1 and n <= 500, do: n
  defp clamp_limit(n) when is_integer(n) and n > 500, do: 500
  defp clamp_limit(_), do: 50

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v) when is_binary(v), do: v
  defp nilify(_), do: nil
end
