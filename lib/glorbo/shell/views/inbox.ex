defmodule Glorbo.Shell.Views.Inbox do
  @moduledoc """
  GEP-37 Phase 2 + 2b + 2c — the TUI Inbox view.

  Phase 2 (read-only) shipped: list of `awaiting-approval-*`
  sentinels per company, cursor navigation up/down (arrows + j/k),
  `q` to quit, empty-state placeholder.

  Phase 2b shipped approve/deny actions wired through
  `Glorbo.Actions.set_approval/4` (wave-31-aware). `a` approves;
  `d` denies.

  Phase 2c (this version) adds the deny-reason prompt UX. Pressing
  `d` enters a modal `:deny_prompt` mode where keystrokes accumulate
  into a buffer until Enter submits or Esc cancels. The buffer is
  passed to `set_approval` as `denial_reason:`.

  Implements `TermUI.Elm`. State shape:

      %{
        approvals:       [Inbox.Data.approval_row()],
        cursor:          non_neg_integer(),
        mode:            :list | {:deny_prompt, String.t()},
        company:         String.t() | nil,
        base:            Path.t() | nil,
        last_action:     {:ok | :error, atom(), term()} | nil,
        approve_fn:      function(),  # injected for tests
        loader_fn:       function()   # injected for tests
      }

  ## Boot path

  Production callers pass `base: "..."` + `company: "..."` to
  `init/1`. Tests pass `approvals:` directly + optional `approve_fn:`
  / `loader_fn:` to mock side effects.
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Inbox.Data
  alias TermUI.Event.Key

  @typedoc "Modal mode — `:list` or a deny-prompt with an accumulating buffer."
  @type mode :: :list | {:deny_prompt, String.t()}

  @typedoc "Inbox view state."
  @type state :: %{
          approvals: [Data.approval_row()],
          cursor: non_neg_integer(),
          mode: mode(),
          company: String.t() | nil,
          base: Path.t() | nil,
          last_action: {:ok | :error, atom(), term()} | nil,
          approve_fn: (-> term()) | function(),
          loader_fn: (-> term()) | function()
        }

  @impl TermUI.Elm
  def init(opts) do
    approve_fn = Keyword.get(opts, :approve_fn, &Glorbo.Actions.set_approval/4)
    loader_fn = Keyword.get(opts, :loader_fn, &Data.load_approvals/2)
    company = Keyword.get(opts, :company)
    base = Keyword.get(opts, :base)

    approvals =
      cond do
        Keyword.has_key?(opts, :approvals) ->
          Keyword.fetch!(opts, :approvals)

        is_binary(company) and is_binary(base) ->
          loader_fn.(base, company)

        true ->
          []
      end

    %{
      approvals: approvals,
      cursor: 0,
      mode: :list,
      company: company,
      base: base,
      last_action: nil,
      approve_fn: approve_fn,
      loader_fn: loader_fn
    }
  end

  @impl TermUI.Elm
  # Deny-prompt modal absorbs every keystroke for buffer editing.
  # Branched first so list-mode bindings don't leak in.
  def event_to_msg(%Key{key: :enter}, %{mode: {:deny_prompt, _}}), do: {:msg, :deny_prompt_submit}

  def event_to_msg(%Key{key: :escape}, %{mode: {:deny_prompt, _}}),
    do: {:msg, :deny_prompt_cancel}

  def event_to_msg(%Key{key: :backspace}, %{mode: {:deny_prompt, _}}),
    do: {:msg, :deny_prompt_backspace}

  def event_to_msg(%Key{key: :char, char: ch}, %{mode: {:deny_prompt, _}})
      when is_binary(ch) and byte_size(ch) > 0,
      do: {:msg, {:deny_prompt_input, ch}}

  def event_to_msg(_event, %{mode: {:deny_prompt, _}}), do: :ignore

  # List-mode bindings.
  def event_to_msg(%Key{key: :up}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :down}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "j"}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "k"}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :char, char: "a"}, _state), do: {:msg, :approve}
  def event_to_msg(%Key{key: :char, char: "d"}, _state), do: {:msg, :deny}
  def event_to_msg(%Key{key: :char, char: "q"}, _state), do: {:msg, :quit}
  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update(:cursor_down, state) do
    last = max(0, length(state.approvals) - 1)
    {%{state | cursor: min(state.cursor + 1, last)}, []}
  end

  def update(:cursor_up, state) do
    {%{state | cursor: max(state.cursor - 1, 0)}, []}
  end

  def update({:approvals_changed, list}, state) do
    {%{state | approvals: list, cursor: clamp_cursor(state.cursor, length(list))}, []}
  end

  def update(:approve, state), do: apply_decision(state, :approved, nil)

  # Deny in list mode opens the prompt instead of submitting; buffer
  # starts empty. Phase 2c modal — Enter submits, Esc cancels.
  def update(:deny, state) do
    {%{state | mode: {:deny_prompt, ""}}, []}
  end

  def update({:deny_prompt_input, ch}, %{mode: {:deny_prompt, buf}} = state) do
    {%{state | mode: {:deny_prompt, buf <> ch}}, []}
  end

  def update(:deny_prompt_backspace, %{mode: {:deny_prompt, ""}} = state),
    do: {state, []}

  def update(:deny_prompt_backspace, %{mode: {:deny_prompt, buf}} = state) do
    new_buf = String.slice(buf, 0, String.length(buf) - 1)
    {%{state | mode: {:deny_prompt, new_buf}}, []}
  end

  def update(:deny_prompt_submit, %{mode: {:deny_prompt, buf}} = state) do
    reason = if buf == "", do: nil, else: buf
    {new_state, cmds} = apply_decision(%{state | mode: :list}, :denied, reason)
    {new_state, cmds}
  end

  def update(:deny_prompt_cancel, %{mode: {:deny_prompt, _}} = state) do
    {%{state | mode: :list}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    body =
      if state.approvals == [] do
        text("Inbox empty — no pending approvals.")
      else
        stack(:vertical, render_approval_lines(state))
      end

    body
    |> append_action_line(state)
    |> append_deny_prompt(state)
  end

  defp append_action_line(body, state) do
    case Map.get(state, :last_action) do
      nil ->
        body

      {:ok, action, _} ->
        stack(:vertical, [body, text("✓ #{action}")])

      {:error, action, reason} ->
        stack(:vertical, [body, text("✗ #{action} failed: #{inspect(reason)}")])
    end
  end

  defp append_deny_prompt(body, state) do
    case Map.get(state, :mode, :list) do
      :list ->
        body

      {:deny_prompt, buf} ->
        stack(:vertical, [
          body,
          text("Deny reason (Enter to submit, Esc to cancel):"),
          text("> #{buf}_")
        ])
    end
  end

  # ----------------------------------------------------------------
  # Phase 2b — action plumbing
  # ----------------------------------------------------------------

  # Apply approve/deny against the cursor row. No-ops gracefully when:
  #
  #   * The approvals list is empty (cursor row doesn't exist).
  #   * The cursor row's `task_path` is nil (sentinel without a
  #     matching task file — only Phase 2c's "clear dangling
  #     sentinel" action can recover those).
  #   * `company` or `base` are missing (init was passed
  #     `approvals:` directly without enough state to act on).
  defp apply_decision(state, decision, denial_reason) do
    with %{} = row <- Enum.at(state.approvals, state.cursor),
         tp when is_binary(tp) <- row.task_path,
         co when is_binary(co) <- state.company,
         base when is_binary(base) <- state.base do
      opts = [base: base]

      opts =
        if is_binary(denial_reason),
          do: Keyword.put(opts, :denial_reason, denial_reason),
          else: opts

      result = state.approve_fn.(co, tp, decision, opts)
      apply_decision_result(state, decision, result)
    else
      _ -> {%{state | last_action: {:error, decision, :no_actionable_row}}, []}
    end
  end

  defp apply_decision_result(state, decision, :ok) do
    refreshed = state.loader_fn.(state.base, state.company)

    new_state = %{
      state
      | approvals: refreshed,
        cursor: clamp_cursor(state.cursor, length(refreshed)),
        last_action: {:ok, decision, nil}
    }

    {new_state, []}
  end

  defp apply_decision_result(state, decision, {:error, reason}) do
    {%{state | last_action: {:error, decision, reason}}, []}
  end

  defp apply_decision_result(state, decision, other) do
    {%{state | last_action: {:error, decision, {:unexpected, other}}}, []}
  end

  defp render_approval_lines(%{approvals: approvals, cursor: cursor}) do
    approvals
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      prefix = if idx == cursor, do: "> ", else: "  "
      assignee = row.assignee || "unassigned"
      text("#{prefix}#{row.task_id} — #{row.title} [#{assignee}]")
    end)
  end

  defp clamp_cursor(_cursor, 0), do: 0

  defp clamp_cursor(cursor, len) when cursor >= len, do: len - 1

  defp clamp_cursor(cursor, _len), do: cursor
end
