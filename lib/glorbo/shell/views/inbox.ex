defmodule Glorbo.Shell.Views.Inbox do
  @moduledoc """
  GEP-37 Phase 2 + 2b — the TUI Inbox view.

  Phase 2 (read-only) shipped: list of `awaiting-approval-*`
  sentinels per company, cursor navigation up/down (arrows + j/k),
  `q` to quit, empty-state placeholder.

  Phase 2b (this version) adds approve/deny actions wired through
  `Glorbo.Actions.set_approval/4` (which is wave-31-aware: company-
  scoped Gate calls + composite-key SQL writes). Single-keystroke
  bindings: `a` approves the cursor row, `d` denies it. Phase 2c
  will add the deny-reason prompt UX (today denies submit with
  reason: nil, which `set_approval` accepts).

  Implements `TermUI.Elm`. State shape:

      %{
        approvals:       [Inbox.Data.approval_row()],
        cursor:          non_neg_integer(),
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

  @typedoc "Inbox view state."
  @type state :: %{
          approvals: [Data.approval_row()],
          cursor: non_neg_integer(),
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
      company: company,
      base: base,
      last_action: nil,
      approve_fn: approve_fn,
      loader_fn: loader_fn
    }
  end

  @impl TermUI.Elm
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

  def update(:approve, state), do: apply_decision(state, :approved)

  def update(:deny, state), do: apply_decision(state, :denied)

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    body =
      if state.approvals == [] do
        text("Inbox empty — no pending approvals.")
      else
        stack(:vertical, render_approval_lines(state))
      end

    case state[:last_action] do
      nil ->
        body

      {:ok, action, _} ->
        stack(:vertical, [body, text("✓ #{action}")])

      {:error, action, reason} ->
        stack(:vertical, [body, text("✗ #{action} failed: #{inspect(reason)}")])
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
  defp apply_decision(state, decision) do
    with %{} = row <- Enum.at(state.approvals, state.cursor),
         tp when is_binary(tp) <- row.task_path,
         co when is_binary(co) <- state.company,
         base when is_binary(base) <- state.base do
      result = state.approve_fn.(co, tp, decision, base: base)
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
