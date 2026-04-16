defmodule Glorbo.Init.Orchestrator do
  @moduledoc """
  7-step init pipeline (D-21). Continue-on-error (D-20). One audit event
  per step (D-24). Severity-weighted final exit code (0/1/2) per D-45.

  Steps, in order:

    1. `:pre_doctor`       — `Glorbo.Doctor.run_checks/0`
    2. `:hierarchy`        — `Glorbo.Filesystem.Hierarchy.ensure!/1`
    3. `:binary_bootstrap` — `BinaryBootstrap.ensure_podman/1` + `ensure_ollama/1`
    4. `:image_pull`       — `ImagePull.run/1`
    5. `:example_company`  — `ExampleCompany.scaffold!/1` (unless `--no-example`)
    6. `:reindex`          — `Reindex.run/1`
    7. `:post_doctor`      — `Glorbo.Doctor.run_checks/0` (exit-code source)

  W3: AuditLog is started unconditionally at pipeline entry; the
  `{:error, {:already_started, _pid}}` reply on rerun is handled
  explicitly. No `Process.whereis/1` race.

  W4: `combine/1` uses `match?/2` — no broken `== {:ok, :system, :_}`
  pattern, no `elem_match` helper.
  """

  require Logger

  alias Glorbo.Doctor
  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.{Hierarchy, Reindex}
  alias Glorbo.Init.{BinaryBootstrap, ImagePull, ExampleCompany}

  @type status :: :ok | :skipped | :error

  @type step_result :: %{
          :step => atom(),
          :status => status(),
          :detail => String.t(),
          optional(:post_doctor_code) => 0 | 1 | 2
        }

  @type summary :: %{
          results: [step_result()],
          exit_code: 0 | 1 | 2,
          failures: [step_result()],
          next_steps: [String.t()]
        }

  @spec run(keyword()) :: {:ok | :error, summary()}
  def run(opts \\ []) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    opts_with_base = Keyword.put(opts, :base, base)

    # WR-05: wrap the pre-pipeline bootstrap so an exception (e.g. EACCES on
    # a non-writable $HOME) doesn't escape `run/1`. D-20 contracts
    # continue-on-error, and callers expect the `{:error, summary}` tuple
    # rather than a raw raise — which is what the pipeline promise is.
    case bootstrap(base) do
      :ok ->
        run_pipeline(opts_with_base)

      {:error, failure} ->
        summary = %{
          results: [failure],
          exit_code: 1,
          failures: [failure],
          next_steps: []
        }

        {:error, summary}
    end
  end

  defp bootstrap(base) do
    # Hierarchy FIRST so the audit directory exists before the first append.
    Hierarchy.ensure!(base)

    # W3: unconditional start_link; handle :already_started explicitly. No
    # Process.whereis/1 race.
    start_audit_log(base)
    :ok
  rescue
    e ->
      {:error, %{step: :hierarchy, status: :error, detail: Exception.message(e)}}
  end

  defp run_pipeline(opts_with_base) do
    steps = [
      {:pre_doctor, fn o -> step_pre_doctor(o) end},
      {:hierarchy, fn o -> step_hierarchy(o) end},
      {:binary_bootstrap, fn o -> step_binary_bootstrap(o) end},
      {:image_pull, fn o -> ImagePull.run(o) end},
      {:example_company, fn o -> step_example_company(o) end},
      {:reindex, fn o -> step_reindex(o) end},
      {:post_doctor, fn o -> step_post_doctor(o) end}
    ]

    results =
      Enum.map(steps, fn {name, fun} ->
        print_start(name)

        result =
          try do
            r = fun.(opts_with_base)
            Map.put(r, :step, name)
          rescue
            e ->
              %{step: name, status: :error, detail: Exception.message(e)}
          end

        audit_step(result)
        print_line(result)
        result
      end)

    summary = summarize(results)

    if summary.exit_code == 1, do: {:error, summary}, else: {:ok, summary}
  end

  # ------ step implementations ------

  defp step_pre_doctor(opts) do
    checks = run_doctor(opts)
    code = Doctor.exit_code(checks)
    %{status: code_to_status(code), detail: "pre-doctor exit #{code}"}
  end

  defp step_hierarchy(opts) do
    Hierarchy.ensure!(Keyword.fetch!(opts, :base))
    %{status: :ok, detail: "~/.glorbo/ materialised"}
  end

  defp step_binary_bootstrap(opts) do
    if Keyword.get(opts, :skip_pull, false) do
      %{status: :skipped, detail: "--skip-pull"}
    else
      podman_fun = Keyword.get(opts, :ensure_podman_fun, &BinaryBootstrap.ensure_podman/1)
      ollama_fun = Keyword.get(opts, :ensure_ollama_fun, &BinaryBootstrap.ensure_ollama/1)

      pr = podman_fun.(opts)
      or_ = ollama_fun.(opts)
      combine([pr, or_])
    end
  end

  defp step_example_company(opts) do
    if Keyword.get(opts, :example, true) do
      case ExampleCompany.scaffold!(opts) do
        :ok -> %{status: :ok, detail: "acme scaffolded"}
        :already_exists -> %{status: :skipped, detail: "acme already present"}
      end
    else
      %{status: :skipped, detail: "--no-example"}
    end
  end

  defp step_reindex(opts) do
    case Reindex.run(opts) do
      {:ok, m} ->
        %{
          status: :ok,
          detail: "indexed=#{m.indexed} skipped=#{m.skipped} deleted=#{m.deleted}"
        }

      other ->
        %{status: :error, detail: inspect(other)}
    end
  end

  defp step_post_doctor(opts) do
    checks = run_doctor(opts)
    code = Doctor.exit_code(checks)
    %{status: code_to_status(code), detail: "post-doctor exit #{code}", post_doctor_code: code}
  end

  # Allows tests to inject a fake doctor result list without touching the real
  # host. Production calls `Doctor.run_checks/0` verbatim.
  defp run_doctor(opts) do
    case Keyword.get(opts, :doctor_fun) do
      nil -> Doctor.run_checks()
      fun when is_function(fun, 0) -> fun.()
      fun when is_function(fun, 1) -> fun.(opts)
    end
  end

  # W4: uses match?/2 — no broken :_ literal, no elem_match helper.
  @doc false
  def combine(results) do
    cond do
      Enum.all?(results, &match?({:ok, :system, _}, &1)) ->
        %{status: :ok, mode: :no_op, detail: "all binaries already present (system)"}

      Enum.any?(results, &match?({:error, _}, &1)) ->
        errors = Enum.filter(results, &match?({:error, _}, &1))

        %{
          status: :error,
          errors: errors,
          detail: "binary bootstrap had errors: #{inspect(errors)}"
        }

      true ->
        %{status: :ok, mode: :mixed, detail: "bootstrapped (mixed system/downloaded)"}
    end
  end

  # ------ helpers ------

  defp start_audit_log(base) do
    case AuditLog.start_link(name: AuditLog, base: base, company: "_system") do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, other} -> raise "AuditLog start failed: #{inspect(other)}"
    end
  end

  defp code_to_status(0), do: :ok
  defp code_to_status(2), do: :skipped
  defp code_to_status(_), do: :error

  defp audit_step(%{step: step, status: status, detail: detail}) do
    # AuditLog.append/2 is a synchronous GenServer call; ignore its return.
    _ =
      AuditLog.append(%{
        company: "_system",
        actor: "init",
        action: "init.step.#{step}",
        target: to_string(step),
        status: to_string(status),
        detail: detail
      })

    :ok
  end

  defp print_start(name), do: IO.puts("⧖ #{name} ...")

  defp print_line(%{step: step, status: :ok, detail: d}),
    do: IO.puts("  ✓ #{step} — #{d}")

  defp print_line(%{step: step, status: :skipped, detail: d}),
    do: IO.puts("  ⏭ #{step} — #{d}")

  defp print_line(%{step: step, status: :error, detail: d}),
    do: IO.puts("  ✗ #{step} — #{d}")

  defp summarize(results) do
    failures = Enum.filter(results, &(&1.status == :error))
    post_doctor = Enum.find(results, &(&1.step == :post_doctor))
    post_code = Map.get(post_doctor || %{}, :post_doctor_code, 0)

    code =
      cond do
        Enum.any?(failures, &(&1.step in [:pre_doctor, :post_doctor, :hierarchy])) ->
          1

        failures != [] and post_code == 0 ->
          2

        true ->
          post_code
      end

    %{
      results: results,
      exit_code: code,
      failures: failures,
      next_steps: build_next_steps(results)
    }
  end

  # Q-A2: the Ollama-UDS hint for offline LLM inference. The actual Director
  # that uses the UDS is Phase 3; Plan 04 surfaces the recipe here as a
  # "next steps" block in the init post-run summary.
  defp build_next_steps(_results) do
    [
      "To run offline LLM inference after init:",
      "  1. mkdir -p /tmp && OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &",
      "  2. ollama pull llama3.2:1b",
      "  3. See EXAMPLE_COMPANY_README.md for the airplane-mode ritual."
    ]
  end
end
