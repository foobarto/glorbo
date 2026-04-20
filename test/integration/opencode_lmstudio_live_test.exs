defmodule Glorbo.Integration.OpencodeLmstudioLiveTest do
  @moduledoc """
  Live end-to-end smoke for the opencode + LM Studio + qwen pipeline.

  Actually invokes the `opencode` binary under `bwrap`, which in turn
  calls the local LM Studio OpenAI-compatible server on
  `http://localhost:1234/v1` running a qwen model. Verifies the full
  stack — Parser → Dispatch → bwrap → opencode → LM Studio → reply —
  really produces a reply Glorbo can render.

  ## When this test runs

  Tagged `:integration` + `:live_model`. Skipped by default; opt in with:

      mix test --include integration --include live_model test/integration/opencode_lmstudio_live_test.exs

  Additionally, the test body self-skips (via `IO.puts` + early return)
  when any precondition is missing:

    * `opencode` binary not on PATH or at `~/.opencode/bin/opencode`
    * `bwrap` not installed
    * LM Studio not reachable at `http://localhost:1234/v1/models`
    * Configured model (`lmstudio/qwen/qwen3.6-35b-a3b`) not in that list

  This keeps the test hermetic-friendly — it becomes a passing no-op on
  machines that don't have the live stack, rather than failing CI.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :live_model

  alias Glorbo.Agent.Dispatch
  alias Glorbo.Agent.Parser
  alias Glorbo.Test.TmpGlorboHome

  @model "lmstudio/qwen/qwen3.6-35b-a3b"
  @lmstudio_url "http://127.0.0.1:1234/v1/models"

  defp opencode_binary do
    System.find_executable("opencode") ||
      case Path.expand("~/.opencode/bin/opencode") do
        path ->
          if File.regular?(path) and
               File.stat!(path).access in [:read_write, :read_execute, :read, :write_execute],
             do: path,
             else: nil
      end
  end

  defp bwrap_binary, do: System.find_executable("bwrap")

  defp lmstudio_has_model?(model) do
    # opencode addresses LM Studio models as `lmstudio/<id>`; the
    # OpenAI-compatible API returns just `<id>` in the `data[].id`
    # field. Strip the `lmstudio/` prefix before substring-checking.
    lookup =
      case model do
        "lmstudio/" <> rest -> rest
        other -> other
      end

    case System.cmd("curl", ~w(-sf #{@lmstudio_url}), stderr_to_stdout: true) do
      {json, 0} -> String.contains?(json, lookup)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp preflight_skip_reason do
    cond do
      is_nil(opencode_binary()) -> "opencode binary not installed"
      is_nil(bwrap_binary()) -> "bwrap not installed"
      not lmstudio_has_model?(@model) -> "LM Studio not serving #{@model} at #{@lmstudio_url}"
      true -> nil
    end
  end

  describe "live dispatch: opencode → lmstudio → qwen → reply" do
    test "a wake + one-shot prompt produces a non-empty reply" do
      case preflight_skip_reason() do
        nil ->
          run_dispatch_and_assert()

        reason ->
          IO.puts(:stderr, "skipping opencode_lmstudio_live_test: #{reason}")
      end
    end
  end

  # Extracted so the test body stays terse. Everything past this point
  # assumes the preflight cleared.
  defp run_dispatch_and_assert do
    base = TmpGlorboHome.setup()
    Application.put_env(:glorbo, :glorbo_base, base)
    on_exit(fn -> Application.delete_env(:glorbo, :glorbo_base) end)

    company = "live#{System.unique_integer([:positive])}"
    slug = "qwen-1"

    agent_md = seed_workspace(base, company, slug)

    {:ok, spec} = Parser.parse_file(agent_md)

    task = %{
      task_id: "smoke-1",
      task_path: "smoke-1.md",
      prompt:
        "Reply with exactly the literal string 'smoke-ok-#{:rand.uniform(100_000)}' and nothing else.",
      trigger: :director
    }

    # Real provider + real bwrap; stub the per-company audit log (not
    # booted in this minimal test) and usage recorder (we're untracked
    # anyway). Everything else — Registry, Dispatcher, sandbox argv
    # assembly, opencode subprocess — is the live production path.
    result =
      Dispatch.execute(spec, task,
        audit_fun: fn _company, _entry -> :ok end,
        record_usage_fun: fn _spec, _task, _usage -> :ok end
      )

    assert {:ok, %{reply: reply, exit_status: 0}} = result,
           "Dispatch failed: #{inspect(result)}"

    assert is_binary(reply) and byte_size(reply) > 0
    # qwen often wraps in a leading newline — match substring.
    assert reply =~ "smoke-ok-",
           "expected reply to contain 'smoke-ok-...', got: #{inspect(reply)}"
  end

  defp seed_workspace(base, company, slug) do
    co_root = Path.join([base, "companies", company])

    for dir <- [
          Path.join([co_root, "agents", slug, "inbox", "mentions"]),
          Path.join([co_root, "agents", slug, "outbox"]),
          Path.join([co_root, "agents", slug, "workspace"]),
          Path.join([co_root, "agents", slug, "state"]),
          Path.join([co_root, "agents", slug, "history"]),
          Path.join([co_root, "channels"]),
          Path.join([base, "audit", "_system"])
        ] do
      File.mkdir_p!(dir)
    end

    File.write!(Path.join(co_root, "company.md"), """
    ---
    slug: #{company}
    name: #{company}
    mission: Live opencode smoke.
    ---
    """)

    agent_md = Path.join([co_root, "agents", slug, "agent.md"])

    File.write!(agent_md, """
    ---
    slug: #{slug}
    name: #{slug}
    role: Opencode LM Studio smoke
    provider: opencode
    model: #{@model}
    allow_untracked_budget: true
    permissions: []
    ---
    """)

    agent_md
  end
end
