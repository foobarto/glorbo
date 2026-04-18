defmodule Glorbo.CLI.Lifecycle.Run do
  @moduledoc """
  `glorbo run <company>/<agent> <task-file>` — D-10: one-shot agent
  dispatch without the LiveView dashboard.

  Flow:

    1. Parse argv: `[co_slash_ag, task_file]`.
    2. Start supervision tree (same call as `serve`) so Agent.Registry +
       AuditLog + Repo are live.
    3. Parse agent.md via `Glorbo.Agent.Parser.parse_file/1` → `Spec`.
    4. Parse task file via `Glorbo.TaskDefinition.parse_file/2`.
    5. `Glorbo.Agent.Dispatch.execute(spec, task, opts)` (opts may be
       overridden by the test harness via the `:dispatch_fun` opt for
       deterministic assertions).
    6. Return summary → exit 0 on `{:ok, result}`, exit 2 on `{:error, _}`.

  This verb is the "cron + CI" entry point: deterministic,
  non-interactive, no long-running state. It exits when the dispatch
  finishes.
  """

  alias Glorbo.CLI.Audit

  @switches [help: :boolean]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:help] ->
        {:run, 0, help_text()}

      length(positional) < 2 ->
        {:run, 1,
         "Usage: glorbo run <company>/<agent> <task-file>\n" <>
           "Example: glorbo run acme/ceo projects/website/tasks/t-01.md\n"}

      true ->
        [co_slash_ag, task_file | _] = positional
        do_run(co_slash_ag, task_file, opts)
    end
  end

  defp do_run(co_slash_ag, task_file, _opts) do
    case String.split(co_slash_ag, "/", parts: 2) do
      [company, agent] when byte_size(company) > 0 and byte_size(agent) > 0 ->
        execute(company, agent, task_file)

      _ ->
        {:run, 1, "Usage: glorbo run <company>/<agent> <task-file>\n"}
    end
  end

  defp execute(company, agent, task_file) do
    Audit.emit("run", "start", %{company: company, agent: agent, task: task_file})

    base = glorbo_home()

    with :ok <- ensure_tree_started(),
         agent_dir <- Path.join([base, "companies", company, "agents", agent]),
         spec_path <- Glorbo.Agent.FileLayout.agent_md(agent_dir),
         {:ok, spec} <- Glorbo.Agent.Parser.parse_file(spec_path),
         task_path <- resolve_task_path(base, company, task_file),
         {:ok, task_def} <-
           Glorbo.TaskDefinition.parse_file(task_path, base: base, company: company),
         task <- task_from_def(task_def, task_path),
         {:ok, result} <- Glorbo.Agent.Dispatch.execute(spec, task, []) do
      Audit.emit("run", "complete", %{
        company: company,
        agent: agent,
        task: task_file,
        exit_status: Map.get(result, :exit_status, 0)
      })

      {:run, 0,
       "Task #{task_file} completed for #{company}/#{agent} " <>
         "(exit=#{Map.get(result, :exit_status, 0)}, " <>
         "duration_ms=#{Map.get(result, :duration_ms, 0)}).\n"}
    else
      {:error, reason} ->
        {:run, 2,
         "Failed to run task #{task_file} for #{company}/#{agent}: #{inspect(reason)}.\n" <>
           "Run `glorbo doctor` to diagnose.\n"}

      {:stopped, _reason} = stopped ->
        {:run, 2,
         "Dispatch stopped: #{inspect(stopped)}. Run `glorbo status` or `glorbo doctor`.\n"}
    end
  end

  defp ensure_tree_started do
    case Glorbo.Application.start_supervision_tree_for_serve() do
      {:ok, _pid} -> :ok
      {:ok, :already_started, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> {:error, {:start_supervision_tree, other}}
    end
  end

  # Accept both absolute paths and paths relative to the company dir.
  defp resolve_task_path(base, company, task_file) do
    if Path.type(task_file) == :absolute do
      task_file
    else
      Path.join([base, "companies", company, task_file])
    end
  end

  # Shape the Dispatch.execute task map from a TaskDefinition struct.
  defp task_from_def(%Glorbo.TaskDefinition{} = def, task_path) do
    %{
      task_id: def.task_id,
      task_path: def.task_path,
      prompt: def.prompt_body,
      trigger: :cli,
      file_path: task_path
    }
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo run — one-shot agent dispatch without the dashboard.

    USAGE
      glorbo run <company>/<agent> <task-file>

    EXAMPLE
      glorbo run acme/ceo projects/website/tasks/t-01.md

    BEHAVIOR
      Starts the supervision tree, parses the agent spec + task, runs a
      single Glorbo.Agent.Dispatch.execute/3 call, prints result, exits.
      Useful for cron and CI without needing the long-running server.
    """
  end
end
