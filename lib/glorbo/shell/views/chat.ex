defmodule Glorbo.Shell.Views.Chat do
  @moduledoc """
  GEP-37 Phase 3f + 3f-revisit — TUI Chat view.

  Phase 3f shipped read-only message rendering. Phase 3f-revisit
  (this version) adds the composer modal: pressing `i` enters
  `{:compose, buffer}` mode where keystrokes accumulate, Enter
  submits via `Glorbo.Actions.post_message/4`, Esc cancels.
  Same modal pattern as Inbox's deny prompt.

  Channel switching + slash-command parsing inside the composer
  are still future work; today the composer always posts to the
  active channel as a plain body.

  Implements `TermUI.Elm`. State shape:

      %{
        messages:    [Chat.Data.message_row()],
        channel:     String.t(),
        cursor:      non_neg_integer(),
        mode:        :list | {:compose, String.t()},
        last_action: {:ok | :error, atom(), term()} | nil,
        company:     String.t() | nil,
        base:        Path.t() | nil,
        loader_fn:   function()  # injected for tests
        post_fn:     function()  # injected for tests
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
      post_fn: post_fn
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

  # List-mode bindings — `i` opens composer first, then fall through to
  # the shared cursor-list nav arms (j/k/arrows/r/q).
  def event_to_msg(%Key{key: :char, char: "i"}, _state), do: {:msg, :compose_open}
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

    stack(:vertical, lines)
  end

  defp append_action_line(lines, state) do
    case Map.get(state, :last_action) do
      nil ->
        lines

      {:ok, :post, _} ->
        lines ++ [text("✓ posted")]

      {:error, :post, reason} ->
        lines ++ [text("✗ post failed: #{inspect(reason)}")]
    end
  end

  defp append_composer(lines, state) do
    case Map.get(state, :mode, :list) do
      :list ->
        lines

      {:compose, buf} ->
        lines ++
          [
            text("Compose (Enter to send, Esc to cancel):"),
            text("> #{buf}_")
          ]
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

  defp apply_post(state, buf) do
    with co when is_binary(co) <- state.company,
         base when is_binary(base) <- state.base do
      result = state.post_fn.(co, state.channel, buf, base: base)
      apply_post_result(state, result)
    else
      _ -> {%{state | mode: :list, last_action: {:error, :post, :no_company}}, []}
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
