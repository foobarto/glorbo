defmodule Glorbo.Shell.Views.Chat.Data do
  @moduledoc """
  GEP-37 Phase 3f — read path for the Chat view.

  Parses `companies/<co>/channels/<channel>.md` by splitting on
  `## <ts> | <author>` headers (the format the LV
  `ChannelLive` uses). Mirrors that view's `parse_messages/2`
  but skips the HEEx markdown rendering — the TUI surfaces
  the raw body text directly.

  Each row carries:

    * `:ts` — string from the `## ` header.
    * `:author` — string from the header.
    * `:body` — message body, trimmed.
  """

  alias Glorbo.ChannelLog

  @typedoc "Slim channel-message row for the TUI Chat view."
  @type message_row :: %{
          ts: String.t(),
          author: String.t(),
          body: String.t()
        }

  @doc """
  Load messages from `companies/<co>/channels/<channel>.md`. Returns
  `[]` when the channel file is missing.
  """
  @spec load_messages(Path.t(), String.t(), String.t()) :: [message_row()]
  def load_messages(base, company, channel) do
    path = Path.join([base, "companies", company, "channels", "#{channel}.md"])

    case File.read(path) do
      {:ok, content} -> parse_messages(content)
      _ -> []
    end
  end

  @doc """
  List the channel slugs a company has on disk. `<channel>.md`
  files directly under `channels/`; `.archive/` is filtered out.
  """
  @spec list_channels(Path.t(), String.t()) :: [String.t()]
  def list_channels(base, company) do
    channels_dir = Path.join([base, "companies", company, "channels"])

    case File.ls(channels_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.rootname(&1, ".md"))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp parse_messages(content) do
    content
    |> ChannelLog.parse_messages()
    |> Enum.map(fn msg ->
      %{
        author: msg.author,
        ts: msg.timestamp,
        body: msg.body,
        provenance: msg.provenance
      }
    end)
  end
end
