defmodule Glorbo.Task.DependencyGate do
  @moduledoc """
  GEP-47 — explicit blocking dependencies for `task/v1`.

  Pure module. No filesystem, no Ecto, no PubSub: take a target task
  plus a snapshot of every task in the company (`task_id → status
  info`) and return one of three readiness verdicts:

    * `:ok` — every dep is in a *done-terminal* state, dispatch may
      proceed.
    * `{:blocked, unmet}` — at least one dep is still non-terminal;
      `unmet` is the list of `task_id`s the caller emits as
      `task.blocked_on_deps` audit (deduped on the caller side).
    * `{:propagate_failure, dep_id, reason}` — at least one dep is
      *failure-terminal*; the caller rewrites the dependent's
      `status` to `cancelled` with `cancelled_reason: reason` and
      emits `task.failure_propagated`.

  ## Snapshot shape

  The `all_tasks` map keys are bare task_id strings
  (`<project-slug>-NN`, GEP-13). Values are maps with these keys
  (extra keys are ignored):

      %{
        status: "todo" | "in-progress" | ... | "done" | "denied" |
                "cancelled" | "approved" | "pending-approval" |
                "pending",
        peer_review_required: boolean(),
        peer_review_verdict: nil | "approve" | "revise" | "block",
        depends_on: [task_id, ...]            # only used by cycle_detect
      }

  Missing entries are treated as failure-terminal — a dep that
  resolves to no live task and no history task is GEP-47's
  validator-finding case (`task.dependency_missing`); the gate
  surfaces it the same way as a `cancelled` upstream so propagation
  kicks in.

  ## Why pure?

  Keeping the logic IO-free means tests can drive every cell of the
  terminal-state classification table (D3) and every cycle topology
  (D8) without setting up a fixture filesystem. Callers — currently
  `Glorbo.Company.TaskScheduler` — own the read-from-disk + write-
  to-disk side; this module owns the rule.
  """

  @typedoc "Snapshot info for one task in the company."
  @type task_info :: %{
          required(:status) => String.t(),
          optional(:peer_review_required) => boolean(),
          optional(:peer_review_verdict) => String.t() | nil,
          optional(:depends_on) => [String.t()]
        }

  @typedoc "task_id → task_info."
  @type snapshot :: %{optional(String.t()) => task_info()}

  @typedoc "Output of `ready?/2`."
  @type verdict ::
          :ok
          | {:blocked, unmet :: [String.t()]}
          | {:propagate_failure, dep_id :: String.t(), reason :: String.t()}

  @typedoc "Output of `cycle_detect/1`."
  @type cycle :: [String.t()]

  @doc """
  Classify the readiness of a task with the given `depends_on` list
  against the company snapshot. The target task itself need not be
  in the snapshot (the caller usually invokes this for a freshly-
  parsed task that's not yet indexed).
  """
  @spec ready?([String.t()], snapshot()) :: verdict()
  def ready?(depends_on, all_tasks)
  def ready?([], _), do: :ok

  def ready?(depends_on, all_tasks) when is_list(depends_on) and is_map(all_tasks) do
    depends_on
    |> Enum.reduce_while({:done, []}, fn dep_id, {:done, unmet} ->
      case classify_dep(dep_id, all_tasks) do
        :done_terminal ->
          {:cont, {:done, unmet}}

        :non_terminal ->
          {:cont, {:done, [dep_id | unmet]}}

        {:failure_terminal, reason} ->
          {:halt, {:propagate, dep_id, reason}}
      end
    end)
    |> finalize()
  end

  defp finalize({:done, []}), do: :ok
  defp finalize({:done, unmet}), do: {:blocked, Enum.reverse(unmet)}
  defp finalize({:propagate, dep_id, reason}), do: {:propagate_failure, dep_id, reason}

  @doc """
  Classify a single referenced task into one of three buckets per
  GEP-47 D3. Exposed for testing; not part of the normal call path.
  """
  @spec classify_dep(String.t(), snapshot()) ::
          :done_terminal
          | :non_terminal
          | {:failure_terminal, reason :: String.t()}
  def classify_dep(dep_id, all_tasks) when is_binary(dep_id) and is_map(all_tasks) do
    case Map.fetch(all_tasks, dep_id) do
      :error ->
        # GEP-47: missing target → propagation kicks in. Validator
        # also surfaces it as `task.dependency_missing`.
        {:failure_terminal, "depends_on target #{dep_id} not found"}

      {:ok, info} ->
        classify_info(dep_id, info)
    end
  end

  defp classify_info(dep_id, info) do
    status = Map.get(info, :status, "")
    pr_required = Map.get(info, :peer_review_required, false) == true
    pr_verdict = Map.get(info, :peer_review_verdict)

    cond do
      status in ["denied", "cancelled"] ->
        {:failure_terminal, "dependency #{dep_id} #{status}"}

      pr_required and pr_verdict == "block" ->
        {:failure_terminal, "dependency #{dep_id} peer-review blocked"}

      status == "done" and (not pr_required or pr_verdict == "approve") ->
        :done_terminal

      true ->
        :non_terminal
    end
  end

  @doc """
  Find every cycle in the company's `depends_on` graph. Returns a
  list of cycles (each cycle is a list of task_ids in traversal
  order, e.g. `["a", "b", "a"]` means a → b → a). Empty list when
  the graph is acyclic.

  Three-colour DFS — O(V+E). Self-loops (A → A) and longer cycles
  (A → B → C → A) both surface. Tasks listed in `depends_on` that
  don't exist in the snapshot are treated as terminal leaves and
  do not produce cycles.
  """
  @spec cycle_detect(snapshot()) :: [cycle()]
  def cycle_detect(all_tasks) when is_map(all_tasks) do
    Enum.reduce(Map.keys(all_tasks), {%{}, []}, fn task_id, {colors, cycles} ->
      case Map.get(colors, task_id) do
        :black ->
          {colors, cycles}

        _ ->
          dfs(task_id, all_tasks, colors, [], cycles)
      end
    end)
    |> elem(1)
    |> Enum.uniq()
  end

  defp dfs(task_id, all_tasks, colors, path, cycles) do
    case Map.get(colors, task_id) do
      :black ->
        {colors, cycles}

      :gray ->
        cycle = Enum.reverse([task_id | path]) |> trim_to_cycle(task_id)
        {colors, [cycle | cycles]}

      _ ->
        colors = Map.put(colors, task_id, :gray)
        deps = (all_tasks[task_id] || %{}) |> Map.get(:depends_on, []) |> List.wrap()

        {colors, cycles} =
          Enum.reduce(deps, {colors, cycles}, fn dep, {c, cy} ->
            if Map.has_key?(all_tasks, dep) do
              dfs(dep, all_tasks, c, [task_id | path], cy)
            else
              {c, cy}
            end
          end)

        {Map.put(colors, task_id, :black), cycles}
    end
  end

  defp trim_to_cycle(path, repeat) do
    idx = Enum.find_index(path, &(&1 == repeat)) || 0
    Enum.drop(path, idx)
  end
end
