defmodule Glorbo.Shell.Views.Chat do
  @moduledoc """
  GEP-37 Phase 3f + 3f-revisit + 3f-revisit-2 + 3f-revisit-3 —
  TUI Chat view.

  Phase 3f shipped read-only message rendering. Phase 3f-revisit
  added the composer modal: `i` enters `{:compose, buffer}` mode
  where keystrokes accumulate, Enter submits via
  `Glorbo.Actions.post_message/4`, Esc cancels. Phase 3f-revisit-2
  added the channel switcher: `s` enters `{:switch, %{channels,
  cursor}}` mode where j/k navigate, Enter selects, Esc cancels.
  Phase 3f-revisit-3 (this version) parses slash commands inside
  the composer: `/switch <ch>` swaps channel, `/help` lists
  commands, `/cancel` exits without posting; unknown commands +
  unknown channels surface in `:last_action`. All three modals
  follow the same shape as Inbox's deny prompt.

  Implements `TermUI.Elm`. State shape:

      %{
        messages:         [Chat.Data.message_row()],
        channel:          String.t(),
        cursor:           non_neg_integer(),
        mode:             :list
                          | {:compose, String.t()}
                          | {:switch, %{channels: [String.t()], cursor: non_neg_integer()}},
        last_action:      {:ok | :error, atom(), term()} | nil,
        company:          String.t() | nil,
        base:             Path.t() | nil,
        loader_fn:        function(),         # injected for tests
        post_fn:          function(),         # injected for tests
        list_channels_fn: function()          # injected for tests
      }
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Chat.Data
  alias Glorbo.Shell.Views.Common
  alias TermUI.Event.Key

  @default_channel "general"

  @impl TermUI.Elm
  def init(opts) do
    loader_fn = Keyword.get(opts, :loader_fn, &Data.load_messages/3)
    post_fn = Keyword.get(opts, :post_fn, &Glorbo.Actions.post_message/4)
    list_channels_fn = Keyword.get(opts, :list_channels_fn, &Data.list_channels/2)
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
      mode: :list,
      last_action: nil,
      company: company,
      base: base,
      loader_fn: loader_fn,
      post_fn: post_fn,
      list_channels_fn: list_channels_fn
    }
  end

  @impl TermUI.Elm
  # Composer modal absorbs every keystroke for buffer editing.
  def event_to_msg(%Key{key: :enter}, %{mode: {:compose, _}}), do: {:msg, :compose_submit}
  def event_to_msg(%Key{key: :escape}, %{mode: {:compose, _}}), do: {:msg, :compose_cancel}

  def event_to_msg(%Key{key: :backspace}, %{mode: {:compose, _}}),
    do: {:msg, :compose_backspace}

  def event_to_msg(%Key{key: :char, char: ch}, %{mode: {:compose, _}})
      when is_binary(ch) and byte_size(ch) > 0,
      do: {:msg, {:compose_input, ch}}

  def event_to_msg(_event, %{mode: {:compose, _}}), do: :ignore

  # Channel switcher modal — j/k/arrows navigate; Enter selects;
  # Esc cancels. Other keys are absorbed so the chord prefix can't
  # leak through.
  def event_to_msg(%Key{key: :enter}, %{mode: {:switch, _}}), do: {:msg, :switch_select}
  def event_to_msg(%Key{key: :escape}, %{mode: {:switch, _}}), do: {:msg, :switch_cancel}
  def event_to_msg(%Key{key: :down}, %{mode: {:switch, _}}), do: {:msg, :switch_cursor_down}
  def event_to_msg(%Key{key: :up}, %{mode: {:switch, _}}), do: {:msg, :switch_cursor_up}

  def event_to_msg(%Key{key: :char, char: "j"}, %{mode: {:switch, _}}),
    do: {:msg, :switch_cursor_down}

  def event_to_msg(%Key{key: :char, char: "k"}, %{mode: {:switch, _}}),
    do: {:msg, :switch_cursor_up}

  def event_to_msg(_event, %{mode: {:switch, _}}), do: :ignore

  # List-mode bindings — `i` opens composer, `s` opens the channel
  # switcher, then fall through to the shared cursor-list nav arms
  # (j/k/arrows/r/q).
  def event_to_msg(%Key{key: :char, char: "i"}, _state), do: {:msg, :compose_open}
  def event_to_msg(%Key{key: :char, char: "s"}, _state), do: {:msg, :switch_open}
  def event_to_msg(event, _state), do: Common.cursor_nav_event(event)

  @impl TermUI.Elm
  def update(:cursor_down, state), do: Common.cursor_down(state, length(state.messages))
  def update(:cursor_up, state), do: Common.cursor_up(state)

  def update(:refresh, state) do
    refreshed =
      if is_binary(state.base) and is_binary(state.company),
        do: state.loader_fn.(state.base, state.company, state.channel),
        else: state.messages

    new_cursor = Common.clamp_cursor(state.cursor, length(refreshed))
    {%{state | messages: refreshed, cursor: new_cursor}, []}
  end

  # Phase 3f-revisit composer arms. Same shape as Inbox's deny-prompt
  # modal: list mode → compose mode (buffered) → submit/cancel.
  def update(:compose_open, state) do
    {%{state | mode: {:compose, ""}}, []}
  end

  def update({:compose_input, ch}, %{mode: {:compose, buf}} = state) do
    {%{state | mode: {:compose, buf <> ch}}, []}
  end

  def update(:compose_backspace, %{mode: {:compose, ""}} = state), do: {state, []}

  def update(:compose_backspace, %{mode: {:compose, buf}} = state) do
    new_buf = String.slice(buf, 0, String.length(buf) - 1)
    {%{state | mode: {:compose, new_buf}}, []}
  end

  def update(:compose_cancel, %{mode: {:compose, _}} = state) do
    {%{state | mode: :list}, []}
  end

  def update(:compose_submit, %{mode: {:compose, buf}} = state) do
    apply_post(state, buf)
  end

  # Phase 3f-revisit-2 channel switcher arms.
  def update(:switch_open, state) do
    if is_binary(state.base) and is_binary(state.company) do
      channels = state.list_channels_fn.(state.base, state.company)
      cursor = Enum.find_index(channels, &(&1 == state.channel)) || 0
      {%{state | mode: {:switch, %{channels: channels, cursor: cursor}}}, []}
    else
      {state, []}
    end
  end

  def update(
        :switch_cursor_down,
        %{mode: {:switch, %{channels: channels, cursor: c} = m}} = state
      ) do
    new_cursor = min(c + 1, max(length(channels) - 1, 0))
    {%{state | mode: {:switch, %{m | cursor: new_cursor}}}, []}
  end

  def update(:switch_cursor_up, %{mode: {:switch, %{cursor: c} = m}} = state) do
    new_cursor = max(c - 1, 0)
    {%{state | mode: {:switch, %{m | cursor: new_cursor}}}, []}
  end

  def update(:switch_cancel, %{mode: {:switch, _}} = state) do
    {%{state | mode: :list}, []}
  end

  def update(:switch_select, %{mode: {:switch, %{channels: [], cursor: _}}} = state) do
    {%{state | mode: :list}, []}
  end

  def update(:switch_select, %{mode: {:switch, %{channels: channels, cursor: c}}} = state) do
    chosen = Enum.at(channels, c)
    refreshed = state.loader_fn.(state.base, state.company, chosen)

    {%{
       state
       | mode: :list,
         channel: chosen,
         messages: refreshed,
         cursor: 0
     }, []}
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

    lines =
      [header, body]
      |> append_action_line(state)
      |> append_composer(state)
      |> append_switcher(state)

    stack(:vertical, lines)
  end

  defp append_action_line(lines, state) do
    case Map.get(state, :last_action) do
      nil ->
        lines

      {:ok, :post, _} ->
        lines ++ [text("✓ posted")]

      {:ok, :help, help_text} ->
        lines ++ [text("ℹ #{help_text}")]

      {:error, :post, reason} ->
        lines ++ [text("✗ post failed: #{inspect(reason)}")]

      {:error, :command, reason} ->
        lines ++ [text("✗ #{format_command_error(reason)}")]
    end
  end

  defp format_command_error({:unknown_command, name}), do: "unknown command: /#{name}"
  defp format_command_error({:unknown_channel, name}), do: "unknown channel: ##{name}"
  defp format_command_error({:missing_argument, name}), do: "missing argument: /#{name} <arg>"
  defp format_command_error(other), do: inspect(other)

  defp append_composer(lines, state) do
    case Map.get(state, :mode, :list) do
      {:compose, buf} ->
        lines ++
          [
            text("Compose (Enter to send, Esc to cancel; /help for commands):"),
            text("> #{buf}_")
          ]

      _ ->
        lines
    end
  end

  defp append_switcher(lines, state) do
    case Map.get(state, :mode, :list) do
      {:switch, %{channels: channels, cursor: cursor}} ->
        header_line = text("Switch channel (j/k navigate, Enter select, Esc cancel):")

        channel_lines =
          channels
          |> Enum.with_index()
          |> Enum.map(fn {ch, idx} ->
            prefix = if idx == cursor, do: "> ", else: "  "
            text("#{prefix}##{ch}")
          end)

        lines ++ [header_line | channel_lines]

      _ ->
        lines
    end
  end

  # ----------------------------------------------------------------

  # Phase 3f-revisit composer write path. Empty buffer is a no-op
  # (cancels back to :list); non-empty calls post_fn with a refresh
  # of messages on success. State carries `last_action` for the
  # post-action feedback line.
  defp apply_post(state, "") do
    {%{state | mode: :list}, []}
  end

  defp apply_post(state, "/" <> rest) do
    apply_command(state, rest)
  end

  defp apply_post(state, buf) do
    with co when is_binary(co) <- state.company,
         base when is_binary(base) <- state.base do
      result = state.post_fn.(co, state.channel, buf, base: base)
      apply_post_result(state, result)
    else
      _ -> {%{state | mode: :list, last_action: {:error, :post, :no_company}}, []}
    end
  end

  # Slash-command parser. Whitespace before the `/` is treated as a
  # regular post (caught by the catch-all apply_post/2 above).
  @help_text "Commands: /switch <ch>, /help, /cancel"

  defp apply_command(state, rest) do
    case String.split(rest, " ", parts: 2, trim: false) do
      ["switch", arg] when arg != "" ->
        apply_switch_command(state, String.trim(arg))

      ["switch"] ->
        {%{state | mode: :list, last_action: {:error, :command, {:missing_argument, "switch"}}},
         []}

      ["switch", ""] ->
        {%{state | mode: :list, last_action: {:error, :command, {:missing_argument, "switch"}}},
         []}

      ["help"] ->
        {%{state | mode: :list, last_action: {:ok, :help, @help_text}}, []}

      ["cancel"] ->
        {%{state | mode: :list}, []}

      [name | _] ->
        {%{state | mode: :list, last_action: {:error, :command, {:unknown_command, name}}}, []}
    end
  end

  defp apply_switch_command(state, channel) do
    if is_binary(state.base) and is_binary(state.company) and
         channel in state.list_channels_fn.(state.base, state.company) do
      refreshed = state.loader_fn.(state.base, state.company, channel)

      {%{
         state
         | mode: :list,
           channel: channel,
           messages: refreshed,
           cursor: 0
       }, []}
    else
      {%{state | mode: :list, last_action: {:error, :command, {:unknown_channel, channel}}}, []}
    end
  end

  defp apply_post_result(state, :ok) do
    refreshed = state.loader_fn.(state.base, state.company, state.channel)

    new_state = %{
      state
      | mode: :list,
        messages: refreshed,
        cursor: Common.clamp_cursor(state.cursor, length(refreshed)),
        last_action: {:ok, :post, nil}
    }

    {new_state, []}
  end

  defp apply_post_result(state, {:error, reason}) do
    {%{state | mode: :list, last_action: {:error, :post, reason}}, []}
  end

  defp apply_post_result(state, other) do
    {%{state | mode: :list, last_action: {:error, :post, {:unexpected, other}}}, []}
  end

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
end
