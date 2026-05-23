defmodule Glorbo.Sandbox.Unsandboxed do
  @moduledoc """
  Unsandboxed CLI runner — the macOS / bwrap-absent fallback (R30.2).

  **This is a pre-1.0 escape hatch.** On Linux hosts bwrap is
  always available and `Glorbo.Sandbox.Bwrap.start/2` is the
  right path. On macOS there is no kernel-level equivalent of
  bwrap mount namespaces yet (see `project_macos_r30_pickup`
  memory + CLAUDE.md "kernel is the policy engine" invariant),
  so the alternative to "refuse to run" is "run unsandboxed and
  tell the director about it".

  The unsandboxed runner:

    * Reuses the same shell wrapper + prompt-tempfile pattern as
      Bwrap (stdin EOF via `< prompt_file`; sh `exec`s the CLI so
      parent-child is direct; prompt tempfile cleaned up on exit).
    * **Skips every isolation flag.** No mount namespaces, no PID
      namespace, no user namespace, no capability drop, no
      network filtering. The CLI sees the director's real
      filesystem, PATH, and env.
    * Preserves stdout tee-ing to `agents/<slug>/stdout.log` so
      the dashboard STDOUT tab + `glorbo logs` still work.

  Callers are expected to emit an `agent.sandbox_unavailable`
  warning audit the first time this path runs per company, so
  directors know agents are running unsandboxed.
  """
  require Logger

  # Same default as Bwrap — avoid runaway CLI subprocesses.
  @default_timeout_seconds 300

  @type run_opts :: [
          cli_binary: Path.t(),
          cli_args: [String.t()],
          prompt: String.t(),
          usage_dir: Path.t() | nil,
          stdout_log: Path.t() | nil,
          cli_env: %{optional(String.t()) => String.t()}
        ]

  @type result ::
          {:ok, %{exit_status: non_neg_integer(), stdout: binary(), usage_dir: Path.t() | nil}}
          | {:error, :timeout | term()}

  @doc """
  Run a CLI tool directly (no sandbox). Mirrors
  `Glorbo.Sandbox.Bwrap.start/2`'s signature; callers pass the
  same invocation opts and run opts, but bwrap-specific keys are
  ignored.
  """
  @spec start(map(), run_opts()) :: result()
  def start(%{} = opts, run_opts) when is_list(run_opts) do
    cli_bin = Keyword.fetch!(run_opts, :cli_binary)
    cli_args = Keyword.get(run_opts, :cli_args, [])
    prompt = Keyword.get(run_opts, :prompt, "")
    usage_dir = Keyword.get(run_opts, :usage_dir)
    stdout_log = Keyword.get(run_opts, :stdout_log)
    cli_env = Map.get(opts, :cli_env, %{})
    timeout_s = Map.get(opts, :timeout_seconds, @default_timeout_seconds)

    run_via_port(cli_bin, cli_args, cli_env, prompt, timeout_s, usage_dir, stdout_log)
  end

  # ------------------------------------------------------------------
  # Port invocation — mirrors Bwrap.run_via_port but without bwrap.
  # ------------------------------------------------------------------

  defp run_via_port(cli_bin, cli_args, cli_env, prompt, timeout_s, usage_dir, stdout_log) do
    case write_prompt_tempfile(prompt) do
      {:ok, prompt_file} ->
        try do
          do_run_via_port(
            cli_bin,
            cli_args,
            cli_env,
            prompt_file,
            timeout_s,
            usage_dir,
            stdout_log
          )
        after
          _ = File.rm(prompt_file)
        end

      {:error, reason} ->
        {:error, {:prompt_tempfile_failed, reason}}
    end
  end

  # Threatmodel wave 23: mirror the bwrap helper's hardened tempfile.
  # 8-byte random suffix + `:file.open([:exclusive])` (O_EXCL refuses
  # to follow a pre-planted symlink) + 0600 mode so other local users
  # can't read the prompt while it's on disk. Prompt text frequently
  # contains agent-routed secrets / API context.
  defp write_prompt_tempfile(prompt) when is_binary(prompt) do
    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    path =
      Path.join(
        System.tmp_dir!(),
        "glorbo_unsandboxed_prompt_#{System.unique_integer([:positive, :monotonic])}_#{rand_suffix}"
      )

    case :file.open(path, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        case :file.write(fd, prompt) do
          :ok ->
            :ok = :file.close(fd)
            _ = File.chmod(path, 0o600)
            {:ok, path}

          {:error, reason} ->
            :ok = :file.close(fd)
            _ = File.rm(path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run_via_port(cli_bin, cli_args, cli_env, prompt_file, timeout_s, usage_dir, stdout_log) do
    sh_path = System.find_executable("sh") || "/bin/sh"
    sh_script = ~s|c="$1"; p="$2"; shift 2; exec "$c" "$@" < "$p"|

    port_args = [sh_script, "glorbo-unsandboxed-launcher", cli_bin, prompt_file | cli_args]

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      {:args, ["-c" | port_args]},
      {:env, env_to_port_pairs(cli_env)}
    ]

    port = Port.open({:spawn_executable, sh_path}, port_opts)

    tee_io = open_stdout_tee(stdout_log)
    write_tee_header(tee_io)

    try do
      case drain_port(port, timeout_s, <<>>, tee_io) do
        {:ok, exit_status, output} ->
          write_tee_footer(tee_io, exit_status)
          {:ok, %{exit_status: exit_status, stdout: output, usage_dir: usage_dir}}

        {:error, :timeout} ->
          Logger.warning("unsandboxed CLI invocation exceeded #{timeout_s}s — brutal_kill issued")
          safe_port_close(port)
          {:error, :timeout}

        {:error, reason} ->
          safe_port_close(port)
          {:error, reason}
      end
    after
      close_stdout_tee(tee_io)
    end
  end

  # Convert the `%{String.t() => String.t()}` env to the
  # `[{charlist, charlist}]` shape Port expects.
  defp env_to_port_pairs(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  # ------------------------------------------------------------------
  # stdout tee (same shape as Bwrap — a future refactor extracts
  # this into a shared module, deferred to R30.3).
  # ------------------------------------------------------------------

  defp open_stdout_tee(nil), do: nil

  defp open_stdout_tee(path) when is_binary(path) do
    _ = File.mkdir_p(Path.dirname(path))

    # Codex deep-dive F7: reuse `AgentWritableFile.ensure_writable/1`
    # so the lstat-before-open policy is shared with the bwrap path
    # (Copilot review on PR #30). Best-effort semantics on this
    # fallback runner — silently degrade to nil on any lstat
    # rejection. See the bwrap.ex mirror for the full threat sketch
    # + residual-TOCTOU rationale.
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> do_open_stdout_tee(path)
      _ -> nil
    end
  end

  defp do_open_stdout_tee(path) do
    case File.open(path, [:append, :binary]) do
      {:ok, io} -> io
      _ -> nil
    end
  end

  defp write_tee_header(nil), do: :ok

  defp write_tee_header(io) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    IO.binwrite(io, "\n--- unsandboxed invocation #{ts} ---\n")
  end

  defp write_tee_footer(nil, _status), do: :ok

  defp write_tee_footer(io, status) do
    IO.binwrite(io, "--- exit #{status} ---\n")
  end

  defp close_stdout_tee(nil), do: :ok
  defp close_stdout_tee(io), do: File.close(io)

  # ------------------------------------------------------------------
  # Port drain — copied from Bwrap; duplication is cheap relative
  # to the shared-helper extraction we'd otherwise need. R30.3
  # factors these out.
  # ------------------------------------------------------------------

  # Codex deep-dive F8: mirror the bwrap drain caps. Previously the
  # unsandboxed path's drain_loop did `acc <> data` per chunk with no
  # ceiling, and the tee `IO.binwrite/2` was unbounded; a malicious or
  # runaway CLI process could balloon BEAM heap AND fill the host
  # filesystem (the tee log is append-mode, persists across
  # dispatches). Same 16 MiB caps used on the bwrap path.
  @stdout_cap 16 * 1024 * 1024
  @tee_cap 16 * 1024 * 1024

  defp drain_port(port, timeout_s, acc, tee_io) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_s * 1000
    drain_loop(port, deadline_ms, acc, tee_io, 0)
  end

  defp drain_loop(port, deadline_ms, acc, tee_io, tee_written) do
    timeout_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        tee_written = tee_write(tee_io, data, tee_written)

        new_acc =
          if byte_size(acc) >= @stdout_cap, do: acc, else: acc <> data

        drain_loop(port, deadline_ms, new_acc, tee_io, tee_written)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc}
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end

  defp tee_write(nil, _chunk, written), do: written
  defp tee_write(_io, _chunk, written) when written >= @tee_cap, do: written

  defp tee_write(io, chunk, written) do
    remaining = @tee_cap - written

    if byte_size(chunk) < remaining do
      IO.binwrite(io, chunk)
      written + byte_size(chunk)
    else
      IO.binwrite(io, binary_part(chunk, 0, remaining))

      IO.binwrite(
        io,
        "\n=== stdout.log truncated: per-dispatch #{@tee_cap}-byte cap reached ===\n"
      )

      @tee_cap
    end
  end

  defp safe_port_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end
end
