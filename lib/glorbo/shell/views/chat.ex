defmodule Glorbo.Shell.Views.Chat do
  @moduledoc """
  GEP-37 Phase 3f — read-only TUI Chat view.

  Renders a single channel's message stream. Each message:
  `[<ts>] <author>: <first body line>` — multi-line bodies are
  collapsed to the first line for the cursor list; pressing
  Enter on a row would expand the full body (deferred to Phase
  3g alongside the composer).

  Phase 3f ships with a fixed default channel (`general`).
  Channel switching + the composer (slash-command surface per
  D10) land in Phase 3g.

  Implements `TermUI.Elm`. State shape:

      %{
        messages:   [Chat.Data.message_row()],
        channel:    String.t(),
        cursor:     non_neg_integer(),
        company:    String.t() | nil,
        base:       Path.t() | nil,
        loader_fn:  function()  # injected for tests
      }
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Chat.Data
  alias TermUI.Event.Key

  @default_channel "general"

  @impl TermUI.Elm
  def init(opts) do
    loader_fn = Keyword.get(opts, :loader_fn, &Data.load_messages/3)
    base = Keyword.get(opts, :base)
    company = Keyword.get(opts, :company)
    channel = Keyword.get(opts, :channel, @default_channel)

    messages =
      cond do
        Keyword.has_key?(opts, :messages) -> Keyword.fetch!(opts, :messages)
        is_binary(base) and is_binary(company) -> loader_fn.(base, company, channel)
        true -> []
      end

    %{
      messages: messages,
      channel: channel,
      cursor: 0,
      company: company,
      base: base,
      loader_fn: loader_fn
    }
  end

  @impl TermUI.Elm
  def event_to_msg(%Key{key: :up}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :down}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "j"}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "k"}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :char, char: "r"}, _state), do: {:msg, :refresh}
  def event_to_msg(%Key{key: :char, char: "q"}, _state), do: {:msg, :quit}
  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update(:cursor_down, state) do
    last = max(0, length(state.messages) - 1)
    {%{state | cursor: min(state.cursor + 1, last)}, []}
  end

  def update(:cursor_up, state) do
    {%{state | cursor: max(state.cursor - 1, 0)}, []}
  end

  def update(:refresh, state) do
    refreshed =
      if is_binary(state.base) and is_binary(state.company),
        do: state.loader_fn.(state.base, state.company, state.channel),
        else: state.messages

    new_cursor = clamp_cursor(state.cursor, length(refreshed))
    {%{state | messages: refreshed, cursor: new_cursor}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    header = text("##{state.channel}")

    body =
      if state.messages == [] do
        text("No messages in ##{state.channel}.")
      else
        stack(:vertical, render_message_lines(state))
      end

    stack(:vertical, [header, body])
  end

  # ----------------------------------------------------------------

  defp render_message_lines(%{messages: messages, cursor: cursor}) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, idx} ->
      prefix = if idx == cursor, do: "> ", else: "  "
      text("#{prefix}[#{format_ts(msg.ts)}] #{msg.author}: #{first_line(msg.body)}")
    end)
  end

  defp first_line(""), do: ""

  defp first_line(body) when is_binary(body) do
    body
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp format_ts(ts) when is_binary(ts) and byte_size(ts) >= 16,
    do: String.slice(ts, 0, 16)

  defp format_ts(ts), do: ts

  defp clamp_cursor(_cursor, 0), do: 0
  defp clamp_cursor(cursor, len) when cursor >= len, do: len - 1
  defp clamp_cursor(cursor, _len), do: cursor
end
