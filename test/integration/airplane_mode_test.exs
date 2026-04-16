defmodule Glorbo.Integration.AirplaneModeTest do
  use ExUnit.Case, async: false

  @moduletag :airplane
  @moduletag :integration
  @moduletag :podman
  @moduletag :ollama

  @moduledoc """
  Phase 2 Success Criterion #6. LLM-05 proof.

  **Manual ritual** — excluded from default runs via three moduletags
  (:airplane, :integration, :podman, :ollama). The Director enables the
  run after completing the preconditions below:

  Preconditions (Director sets up before running):

    1. `glorbo init` has completed successfully on this host
    2. `OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &` is running
    3. `ollama pull llama3.2:1b` has completed
    4. The `glorbo-runtime` image has been pulled (`podman image exists
       ghcr.io/foobarto/glorbo-runtime:v0.1.0` returns 0)

  The test:

    1. Disables host networking via `sudo nmcli networking off` (restored
       on exit via `on_exit/1`).
    2. Starts a persistent container for acme/ceo with a bind-mount from
       `/tmp/ollama.sock` on the host → `/tmp/ollama.sock` inside the
       container (via the `extra_volumes:` keyword added to
       `Glorbo.Container.Invocation.build_argv/4` by Plan 04).
    3. POSTs a `/run` request with `provider=ollama`, `model=llama3.2:1b`.
    4. Asserts a non-empty completion returns within the `timeout_seconds`
       budget (plus container startup slack).

  Q-A3: if `litellm`'s Ollama provider does NOT support the `unix://`
  scheme, the fallback is an `httpx`-over-UDS shim in
  `containers/glorbo-runtime/worker/dispatch.py`. The airplane-mode
  ritual is where that Q-A3 branch is exercised; record the disposition
  in `02-04-SUMMARY.md`.
  """

  alias Glorbo.Container.WorkerClient
  alias Glorbo.ContainerManager

  test "ollama inference executes with host network off" do
    base = Path.expand("~/.glorbo")

    # Precondition check — skip loudly if the Director hasn't set up.
    unless File.exists?("/tmp/ollama.sock") do
      flunk(
        "Precondition failed: /tmp/ollama.sock not found. Start Ollama first:\n" <>
          "  OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &"
      )
    end

    # Step 1: cut host networking (restored on exit).
    case System.cmd("sudo", ["-n", "nmcli", "networking", "off"], stderr_to_stdout: true) do
      {_, 0} ->
        on_exit(fn -> System.cmd("sudo", ["-n", "nmcli", "networking", "on"]) end)

      {out, code} ->
        flunk(
          "Could not disable networking via sudo nmcli (exit #{code}): #{out}\n" <>
            "Director must have sudo NOPASSWD for nmcli, or run the test manually:\n" <>
            "  sudo nmcli networking off && mix test test/integration/airplane_mode_test.exs --include airplane"
        )
    end

    # Step 2: start persistent container with Ollama UDS bind-mount.
    {:ok, _name} =
      ContainerManager.start_container("acme",
        agent: "ceo",
        mode: :persistent,
        base: base,
        extra_volumes: ["/tmp/ollama.sock:/tmp/ollama.sock:Z,rw"]
      )

    # Step 3: seed a trivial task inside the mounted company dir.
    inbox_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox"])
    File.mkdir_p!(inbox_dir)

    task_path = Path.join(inbox_dir, "ping.md")

    File.write!(task_path, """
    ---
    id: ping
    ---
    Say "pong".
    """)

    # Step 4: POST /run — the container path for task_path is /company/...
    container_task_path = "/company/agents/ceo/inbox/ping.md"

    {:ok, resp} =
      WorkerClient.post_run("acme", "ceo", %{
        task_path: container_task_path,
        provider: "ollama",
        model: "llama3.2:1b",
        api_key: nil,
        skills: [],
        timeout_seconds: 30,
        request_id: "airplane-ping-1",
        ollama_host: "unix:///tmp/ollama.sock",
        agent_slug: "ceo",
        outbox_root: "/company"
      })

    assert resp["ok"] == true,
           "Expected {\"ok\": true} from /run, got: #{inspect(resp)}"

    completion = resp["result"]["completion"]
    assert is_binary(completion)
    assert String.length(completion) > 0, "Expected non-empty completion, got empty string"
  end
end
