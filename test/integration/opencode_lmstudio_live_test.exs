defmodule Glorbo.Integration.OpencodeLmstudioLiveTest do
  @moduledoc """
  Live end-to-end smoke for the opencode + LM Studio + qwen pipeline.

  Actually invokes the `opencode` binary under `bwrap`, which in turn
  calls the local LM Studio OpenAI-compatible server on
  `http://localhost:1234/v1` running a qwen model. Verifies the full
  stack — Parser → Dispatch → bwrap → opencode → LM Studio → reply —
  really produces a reply Glorbo can render.

  ## When this test runs

  Tagged `:live_model` only (the previous `:integration` tag was
  redundant — ExUnit's `--include` overrides `--exclude` when tags
  overlap, so `:integration` defeated the default `:live_model`
  exclusion). Opt in explicitly with:

      mix test --include live_model test/integration/opencode_lmstudio_live_test.exs

  Additionally, the test body self-skips (via `IO.puts` + early return)
  when any precondition is missing:

    * `opencode` binary not on PATH or at `~/.opencode/bin/opencode`
    * `bwrap` not installed
    * LM Studio's chat-completions endpoint returns 200 for the
      configured model (covers both "listed" and "loaded")
    * opencode's own provider registry recognises the model — this
      one cannot be preflight-checked from Elixir; misconfiguration
      surfaces as `ProviderModelNotFoundError` inside the dispatch.

  This keeps the test hermetic-friendly — it becomes a passing no-op on
  machines that don't have the live stack, rather than failing CI.
  """
  use ExUnit.Case, async: false

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
    # field. Strip the `lmstudio/` prefix and (1) verify the id is
    # in the model catalog, (2) probe `/v1/chat/completions` to
    # confirm the model is actually loaded — `/v1/models` lists
    # every discoverable model, but only the currently-loaded one
    # serves requests. Without (2) the test passes preflight then
    # fails inside opencode with "model not found."
    lookup =
      case model do
        "lmstudio/" <> rest -> rest
        other -> other
      end

    listed_and_loaded?(lookup)
  rescue
    _ -> false
  end

  defp listed_and_loaded?(model_id) do
    with {:ok, true} <- model_listed?(model_id),
         {:ok, true} <- model_loaded?(model_id) do
      true
    else
      _ -> false
    end
  end

  defp model_listed?(model_id) do
    case System.cmd("curl", ~w(-sf #{@lmstudio_url}), stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, %{"data" => data}} when is_list(data) ->
            {:ok, Enum.any?(data, fn entry -> Map.get(entry, "id") == model_id end)}

          _ ->
            {:ok, false}
        end

      _ ->
        {:ok, false}
    end
  end

  # Tiny chat-completion probe — 1 token, "ping" prompt. If LM
  # Studio responds 200 the model is loaded; 404 / "model not
  # found" means it's listed but not in memory.
  defp model_loaded?(model_id) do
    body =
      Jason.encode!(%{
        model: model_id,
        messages: [%{role: "user", content: "ping"}],
        max_tokens: 1,
        temperature: 0
      })

    args = [
      "-sf",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      "-H",
      "content-type: application/json",
      "-d",
      body,
      "http://127.0.0.1:1234/v1/chat/completions"
    ]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {"200" <> _, _} -> {:ok, true}
      _ -> {:ok, false}
    end
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

    # R17c (#285) — end-to-end agent memory read. Seed a feedback
    # memory with a specific token the agent couldn't guess, ask it
    # to repeat that token, confirm the reply contains it. Proves
    # the full chain — Memory.compose → compose_prompt → bwrap →
    # opencode prompt → model → reply — works live.
    test "agent memory is composed into prompt and referenced by the model" do
      case preflight_skip_reason() do
        nil ->
          run_memory_e2e_and_assert()

        reason ->
          IO.puts(:stderr, "skipping memory e2e: #{reason}")
      end
    end

    # R17c (#285) — end-to-end agent memory write. Dispatch a task
    # that instructs the agent to write a memory via the outbox
    # routing contract (`outbox/memory/<type>_<topic>.md`). After
    # dispatch, confirm the memory file landed at
    # `agents/<slug>/memory/<type>_<topic>.md` via the Router, that
    # `MEMORY.md` was upserted, and that a `memory.write` audit was
    # emitted. Proves the full write chain works under a real
    # model's output.
    test "agent writes a memory via outbox → Router persists it" do
      case preflight_skip_reason() do
        nil ->
          run_memory_write_e2e_and_assert()

        reason ->
          IO.puts(:stderr, "skipping memory-write e2e: #{reason}")
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

  defp run_memory_e2e_and_assert do
    base = TmpGlorboHome.setup()
    Application.put_env(:glorbo, :glorbo_base, base)
    on_exit(fn -> Application.delete_env(:glorbo, :glorbo_base) end)

    company = "mem#{System.unique_integer([:positive])}"
    slug = "mem-1"

    agent_md = seed_workspace(base, company, slug)

    # Seed the memory directory with a feedback entry containing a
    # high-entropy token the model cannot guess. Memory.compose
    # picks it up on the next dispatch; the model's reply must
    # contain the exact token for the test to pass.
    token = "mem-token-#{:rand.uniform(9_999_999)}"
    memory_dir = Path.join([base, "companies", company, "agents", slug, "memory"])
    File.mkdir_p!(memory_dir)

    File.write!(Path.join(memory_dir, "feedback_secret.md"), """
    ---
    kind: agent-memory/v1
    name: Director secret token
    description: unique one-shot token for R17c e2e memory test
    type: feedback
    ---

    The director's secret token is: #{token}

    When asked to recall the secret token, reply with exactly that
    string and nothing else.
    """)

    File.write!(Path.join(memory_dir, "MEMORY.md"), """
    - [Director secret token](feedback_secret.md) — e2e test token
    """)

    {:ok, spec} = Parser.parse_file(agent_md)

    # Simulate what Agent.Server.compose_prompt does — prepend the
    # memory section. Dispatch.execute itself doesn't compose;
    # composition is Agent.Server's job, and this E2E calls Dispatch
    # directly to keep the test narrow. What we're verifying is:
    # given a prompt with memory composed, the model reads it and
    # can reference its contents.
    {:ok, memory_section} = Glorbo.Agent.Memory.compose(base, company, slug)

    task = %{
      task_id: "mem-e2e-1",
      task_path: "mem-e2e-1.md",
      prompt: """
      ## Memory

      #{memory_section}

      ---

      Reply with exactly the director's secret token and nothing else
      (no prefix, no punctuation, no explanation).
      """,
      trigger: :director
    }

    result =
      Dispatch.execute(spec, task,
        audit_fun: fn _company, _entry -> :ok end,
        record_usage_fun: fn _spec, _task, _usage -> :ok end
      )

    assert {:ok, %{reply: reply, exit_status: 0}} = result,
           "Dispatch failed: #{inspect(result)}"

    assert is_binary(reply) and byte_size(reply) > 0

    # The token is the proof — if the model reads memory, it can
    # produce this. If not (memory not composed, or model ignored),
    # the token will be missing.
    assert reply =~ token,
           "expected memory-sourced token #{inspect(token)} in reply, got: #{inspect(reply)}"
  end

  defp run_memory_write_e2e_and_assert do
    base = TmpGlorboHome.setup()
    Application.put_env(:glorbo, :glorbo_base, base)
    on_exit(fn -> Application.delete_env(:glorbo, :glorbo_base) end)

    company = "memw#{System.unique_integer([:positive])}"
    slug = "mem-writer"

    agent_md = seed_workspace(base, company, slug)

    # Start a Router against this tmp base so the agent's outbox
    # writes get processed. Capture audits to a test mailbox.
    test_pid = self()
    audit_fun = fn _co, entry -> send(test_pid, {:audit, entry}) end

    router_name = Glorbo.Test.UniqueName.gen("router_memw_e2e")

    {:ok, _router} =
      Glorbo.Company.Router.start_link(
        name: router_name,
        company: company,
        base: base,
        audit_fun: audit_fun,
        # Tests drive via file-event messages; no need for PubSub.
        subscribe?: false
      )

    on_exit(fn ->
      case Process.whereis(router_name) do
        pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid)
        _ -> :ok
      end
    end)

    {:ok, spec} = Parser.parse_file(agent_md)

    # The prompt deliberately instructs the agent to drop an exact
    # filename with exact frontmatter so success is deterministic.
    # Real-world agents learn this pattern from the glorbo.md
    # skill; for this test we inline it in the task prompt.
    filename = "feedback_ship_on_friday.md"

    task = %{
      task_id: "mem-write-1",
      task_path: "mem-write-1.md",
      prompt: """
      Write a memory file to /outbox/memory/#{filename} with EXACTLY these contents:

      ---
      name: No Friday ships
      description: Director policy on deployment timing
      type: feedback
      ---

      Rule: never ship to prod on Fridays. Roll changes Monday-Thursday.

      Use the Write tool. Do not print the file contents as your
      reply — your reply should just be a short confirmation like
      "done".
      """,
      trigger: :director
    }

    result =
      Dispatch.execute(spec, task,
        audit_fun: audit_fun,
        record_usage_fun: fn _spec, _task, _usage -> :ok end
      )

    assert {:ok, %{exit_status: 0}} = result, "Dispatch failed: #{inspect(result)}"

    # Router processes file events on inotify. Our tmp base has no
    # running FileSystem watcher, so poke the router directly to
    # simulate the event that inotify would fire.
    outbox_path = "agents/#{slug}/outbox/memory/#{filename}"

    # Wait up to 3s for the agent to actually write to outbox.
    _ =
      Enum.reduce_while(1..60, nil, fn _, _ ->
        abs = Path.join([base, "companies", company, outbox_path])

        if File.exists?(abs) do
          {:halt, :ok}
        else
          Process.sleep(50)
          {:cont, nil}
        end
      end)

    send(Process.whereis(router_name), {:file_event, outbox_path, [:created]})
    _ = :sys.get_state(router_name)

    # Memory file now in the canonical location.
    memory_file =
      Path.join([base, "companies", company, "agents", slug, "memory", filename])

    assert File.exists?(memory_file),
           "expected memory at #{memory_file}, not found — model likely didn't write outbox"

    content = File.read!(memory_file)
    assert content =~ "No Friday ships"
    assert content =~ "never ship to prod on Fridays"

    # MEMORY.md index upserted.
    index =
      File.read!(Path.join([base, "companies", company, "agents", slug, "memory", "MEMORY.md"]))

    assert index =~ filename

    # Audit emitted.
    assert_receive {:audit, %{action: "memory.write"}}, 500
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
    kind: company/v1
    slug: #{company}
    name: #{company}
    mission: Live opencode smoke.
    ---
    """)

    agent_md = Path.join([co_root, "agents", slug, "AGENT.md"])

    # GEP-25 R26.2b — `kind: agent/v1` is required on every agent
    # frontmatter; the parser refuses bare frontmatter without it.
    File.write!(agent_md, """
    ---
    kind: agent/v1
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
