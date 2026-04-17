defmodule Glorbo.Integration.InotifyToBwrapHappyPathTest do
  @moduledoc """
  End-to-end happy-path integration test wiring inotify → Watcher →
  PubSub → Router/Agent.Server → Dispatch → Bwrap.build_argv.

  Does NOT invoke a real CLI binary. Instead, `run_fun` is overridden
  with a fake that records the call so the test asserts the full
  pipeline reached Dispatch and built a sandbox invocation.

  Tagged `:integration` + `:inotify` — requires inotify-tools on the
  host; otherwise skipped via the global tag gate in `test_helper.exs`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :inotify

  alias Glorbo.Agent.Registry, as: AgentRegistry
  alias Glorbo.Agent.Server, as: AgentServer
  alias Glorbo.Agent.Spec
  alias Glorbo.Sandbox.Bwrap
  alias Glorbo.Test.TmpGlorboHome

  # Runtime gate helper — even with `--include integration --include inotify`
  # on the CLI, skip gracefully when inotifywait is absent. Keeps unequipped
  # dev boxes from hard-failing on forced includes; production + CI MUST
  # install inotify-tools (enforced by Doctor).
  defp inotify_available?, do: System.find_executable("inotifywait") != nil

  describe "HP1: inotify event → Agent.Server wake → Dispatch → Bwrap argv" do
    test "writing a task to agents/<slug>/inbox/ triggers wake + dispatch with expected bwrap argv" do
      if inotify_available?() do
        run_hp1_assertions()
      else
        IO.puts(:stderr, "skipping HP1 at runtime: inotifywait not installed")
      end
    end
  end

  # Test body extracted to a module-level helper so it compiles cleanly and
  # the describe/test macro stays light.
  defp run_hp1_assertions do
    base = TmpGlorboHome.setup()
    company = "acme-#{System.unique_integer([:positive])}"
    slug = "engineer"

    # Set up company dir skeleton so Watcher + Agent.Server can scan it.
    co_root = Path.join([base, "companies", company])
    agent_dir = Path.join([co_root, "agents", slug])

    for sub <- ~w(inbox outbox workspace state) do
      File.mkdir_p!(Path.join(agent_dir, sub))
    end

    # Agent.Registry may or may not already be running via the app; start if
    # not.
    _ = Registry.start_link(keys: :unique, name: AgentRegistry)

    # Spec matches what Agent.Parser would produce for a claude-code agent
    # with a minimal declaration.
    spec = %Spec{
      slug: slug,
      company: company,
      role: "engineer",
      provider: "claude-code",
      model: "claude-sonnet-4-5",
      permissions: [],
      heartbeat: nil,
      network: :none,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 60,
      file_path: Path.join(agent_dir, "AGENT.md")
    }

    parent = self()

    # run_fun records the invocation + re-composes what production's
    # default_bwrap_run_fun would build so we can assert on the concrete
    # bwrap argv that would have been spawned.
    recording_run_fun = fn argv, env, ^spec, ctx ->
      invocation_opts = %{
        agent_workspace: ctx.workspace,
        inbox_path: ctx.inbox_path,
        outbox_path: ctx.outbox_path,
        company_path: ctx.company_path,
        permissions: ctx.permissions,
        network_policy: ctx.network_policy,
        cli_auth_binds: [],
        cli_env: env,
        proxy_url: ctx.proxy_url,
        timeout_seconds: ctx.timeout_seconds
      }

      bwrap_argv = Bwrap.build_argv(invocation_opts)

      send(parent, {:dispatched, %{argv: argv, env: env, ctx: ctx, bwrap_argv: bwrap_argv}})
      {:ok, %{exit_status: 0, stdout: "ok"}}
    end

    # dispatch_fun wraps Dispatch.execute/3 + injects the recording run_fun
    # + a stub binary_fun so we don't need a real `claude` on PATH.
    dispatch_fun = fn spec, task, opts ->
      opts =
        opts
        |> Keyword.put(:run_fun, recording_run_fun)
        |> Keyword.put(:binary_fun, fn _mod -> "/fake/claude" end)
        |> Keyword.put(:base, base)

      Glorbo.Agent.Dispatch.execute(spec, task, opts)
    end

    # Inbox scanner returns the written task when called.
    inbox_scan_fun = fn _spec ->
      inbox = Path.join(agent_dir, "inbox")

      case File.ls(inbox) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort()
          |> List.first()
          |> case do
            nil ->
              nil

            name ->
              path = Path.join(inbox, name)
              {:ok, body} = File.read(path)

              %{
                task_id: Path.basename(name, ".md"),
                task_path: "projects/foo/tasks/#{Path.basename(name, ".md")}.md",
                prompt: body,
                trigger: :inbox
              }
          end

        _ ->
          nil
      end
    end

    # Start the Watcher (inotify + PubSub broadcast).
    {:ok, watcher_pid} =
      Glorbo.Filesystem.Watcher.start_link(
        company: company,
        base: base,
        name: Glorbo.Test.UniqueName.gen("watcher")
      )

    on_exit(fn -> if Process.alive?(watcher_pid), do: GenServer.stop(watcher_pid) end)

    # Per-agent Task.Supervisor + Agent.Server. The server subscribes to
    # `company:<co>:inbox` by default, so PubSub broadcasts from the Watcher
    # reach it and wake the agent.
    task_sup_name = {:via, Registry, {AgentRegistry, {:agent_task_sup, company, slug}}}
    {:ok, _task_sup} = Task.Supervisor.start_link(name: task_sup_name)

    server_name = {:via, Registry, {AgentRegistry, {:agent_server, company, slug}}}

    {:ok, server_pid} =
      AgentServer.start_link(
        spec: spec,
        company: company,
        task_supervisor: task_sup_name,
        name: server_name,
        dispatch_fun: dispatch_fun,
        inbox_scan_fun: inbox_scan_fun,
        base: base
      )

    on_exit(fn -> if Process.alive?(server_pid), do: GenServer.stop(server_pid) end)

    # Write a task file into the agent's inbox. The inotify subsystem
    # should notice → Watcher broadcasts on `company:<co>:inbox` →
    # Agent.Server's handle_info fires → inbox_scan_fun returns the task
    # → dispatch_fun is called with the task.
    task_file = Path.join([agent_dir, "inbox", "t-hp1.md"])
    File.write!(task_file, "Task: do the thing\n")

    assert_receive {:dispatched, %{argv: argv, env: env, ctx: ctx, bwrap_argv: bwrap_argv}}, 5_000

    # Dispatch emitted the expected claude-code CLI args.
    assert "--print" in argv
    assert "--model" in argv
    assert "claude-sonnet-4-5" in argv

    # Env is populated with the per-agent session redirect.
    assert Map.has_key?(env, "CLAUDE_CONFIG_DIR")

    # Context carries the agent's on-disk paths.
    assert ctx.company_path == co_root
    assert ctx.inbox_path == Path.join(agent_dir, "inbox")
    assert ctx.outbox_path == Path.join(agent_dir, "outbox")
    assert ctx.network_policy == :none

    # Bwrap argv contains the D-08 baseline flags + network isolation +
    # workspace + per-agent paths — what a real sandbox invocation would
    # produce.
    assert "--die-with-parent" in bwrap_argv
    assert "--unshare-pid" in bwrap_argv
    # network: :none → --unshare-net
    assert "--unshare-net" in bwrap_argv
    # workspace bound rw, inbox ro (one-way flow invariant)
    assert bwrap_argv
           |> Enum.chunk_every(3, 1, :discard)
           |> Enum.any?(&(&1 == ["--bind", ctx.workspace, "/workspace"]))

    assert bwrap_argv
           |> Enum.chunk_every(3, 1, :discard)
           |> Enum.any?(&(&1 == ["--ro-bind", ctx.inbox_path, "/inbox"]))
  end
end
