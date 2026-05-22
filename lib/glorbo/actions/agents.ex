defmodule Glorbo.Actions.Agents do
  @moduledoc """
  Agent-directory mutation operations (GEP-36).

  Covers the four writes AgentLive issues against its agent's on-disk
  tree:

    * `create_workspace_file/4` — create an empty file under the agent's
      dir (editor "new file" button).
    * `write_workspace_file/5` — overwrite an existing workspace file.
    * `trash_workspace_file/4` — move a workspace file into the agent's
      `history/deleted/<ts>-<name>` bucket.
    * `retire/3` — move the whole agent directory under
      `agents/.archive/<slug>-<ts>/`.

  All four honor two security invariants:

    * **threatmodel H9** — AGENT.md and stdout.log are refused by every
      generic write path. AGENT.md is the agent's permission + network
      contract; the typed config editor is the only sanctioned writer.
      stdout.log is runtime state.
    * **threatmodel H10** — each path component from the agent dir down
      is `lstat`-checked; any symlink along the way is refused. A string-
      prefix check isn't enough; File.* follows symlinks.

  ## Contract

    * Returns `{:ok, result}` or `{:error, reason}`.
    * `opts` requires `:actor`.
    * Emits `agent.file_create` / `agent.file_write` /
      `agent.file_trash` / `agent.retire` audit entries.
  """

  require Logger

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

  @contract_files ~w(AGENT.md stdout.log)

  @type opts :: [actor: String.t(), base: Path.t(), audit: atom()]

  @doc """
  Create an empty file at `rel_path` under the agent dir. Refuses to
  overwrite an existing file; refuses contract files; refuses any
  symlinked path component.
  """
  @spec create_workspace_file(String.t(), String.t(), String.t(), opts()) ::
          {:ok, %{abs_path: String.t()}} | {:error, term()}
  def create_workspace_file(company, slug, rel_path, opts \\ [])
      when is_binary(company) and is_binary(slug) and is_binary(rel_path) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(slug, :agent),
         :ok <- refuse_contract_write(rel_path),
         agent_root = agent_dir(base, company, slug),
         {:ok, abs_path} <- resolve_workspace_path(agent_root, rel_path),
         :ok <- ensure_no_symlink_on_path(abs_path, agent_root),
         :ok <- guard_not_exists(abs_path),
         :ok <- File.mkdir_p(Path.dirname(abs_path)),
         # Wave 27: close the lstat→File.write TOCTOU window. Exclusive
         # open refuses both an existing file and a freshly-planted
         # symlink at `abs_path` in one syscall.
         :ok <- exclusive_create(abs_path),
         :ok <- emit_audit(audit, company, slug, "agent.file_create", rel_path, actor) do
      {:ok, %{abs_path: abs_path}}
    end
  end

  @doc """
  Overwrite the file at `rel_path` with `content`. Refuses contract
  files and symlinked paths. Caller must have already verified the
  file is writable + not binary; this function is the mutation
  primitive, not the editor policy.
  """
  @spec write_workspace_file(String.t(), String.t(), String.t(), binary(), opts()) ::
          {:ok, %{abs_path: String.t()}} | {:error, term()}
  def write_workspace_file(company, slug, rel_path, content, opts \\ [])
      when is_binary(company) and is_binary(slug) and is_binary(rel_path) and
             is_binary(content) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(slug, :agent),
         :ok <- refuse_contract_write(rel_path),
         agent_root = agent_dir(base, company, slug),
         {:ok, abs_path} <- resolve_workspace_path(agent_root, rel_path),
         :ok <- ensure_no_symlink_on_path(abs_path, agent_root),
         # Wave 27: write to a random-suffix exclusive temp in the same
         # dir, then atomic rename. Closes the lstat→File.write TOCTOU
         # window where `abs_path` could be swapped for a symlink.
         :ok <- atomic_write(abs_path, content),
         :ok <- emit_audit(audit, company, slug, "agent.file_write", rel_path, actor) do
      {:ok, %{abs_path: abs_path}}
    end
  end

  @doc """
  Soft-delete `rel_path` into the agent's own trash
  (`history/deleted/<ts>-<basename>`). Idempotent-safe — if the file
  is already gone, returns `{:error, :not_found}`.
  """
  @spec trash_workspace_file(String.t(), String.t(), String.t(), opts()) ::
          {:ok, %{dest_rel_path: String.t()}} | {:error, term()}
  def trash_workspace_file(company, slug, rel_path, opts \\ [])
      when is_binary(company) and is_binary(slug) and is_binary(rel_path) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(slug, :agent),
         :ok <- refuse_contract_write(rel_path),
         agent_root = agent_dir(base, company, slug),
         {:ok, abs_path} <- resolve_workspace_path(agent_root, rel_path),
         :ok <- ensure_no_symlink_on_path(abs_path, agent_root),
         :ok <- guard_exists(abs_path) do
      ts = System.system_time(:millisecond)
      trash_dir = Path.join([agent_root, "history", "deleted"])

      # Wave 27: refuse a pre-planted `history -> ../../audit` or
      # `history/deleted -> ../../<co>/...` symlink before mkdir_p.
      if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(trash_dir) do
        {:error, :symlinked_ancestor}
      else
        :ok = File.mkdir_p(trash_dir)
        dest_name = "#{ts}-#{Path.basename(rel_path)}"
        dst = Path.join(trash_dir, dest_name)
        dest_rel = Path.join(["history", "deleted", dest_name])

        with :ok <- File.rename(abs_path, dst),
             :ok <- emit_trash_audit(audit, company, slug, rel_path, dest_rel, actor) do
          {:ok, %{dest_rel_path: dest_rel}}
        end
      end
    end
  end

  @doc """
  Retire an agent by moving its whole dir to
  `agents/.archive/<slug>-<ts>/`.

  C-099: retire is a security action — an operator runs it to *stop* an
  untrusted agent. So before archiving the directory we genuinely
  decommission the running process:

    * terminate the company-scoped `AgentSupervisor` sub-tree (the
      `Agent.Server` + its `Task.Supervisor`), which holds the agent's
      old in-memory spec (provider, permissions, network policy), and
    * unregister the heartbeat from the company `Scheduler` so a
      `heartbeat:` cron can't keep firing `wake/1` against the moved
      inbox with the stale spec.

  Both steps are best-effort and run BEFORE the rename so a busy server
  can't pop a pending dispatch against the directory mid-move. A
  not-running agent (idle / no scheduler entry / unsupervised test
  harness) is a no-op. The OTP-touching seams are dep-injectable via
  `:stop_agent_fun` / `:unregister_fun` so unit tests can assert the
  stop happens without standing up a full company tree.
  """
  @spec retire(String.t(), String.t(), opts()) ::
          {:ok, %{archive_rel_path: String.t()}} | {:error, term()}
  def retire(company, slug, opts \\ [])
      when is_binary(company) and is_binary(slug) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "agent.retire",
      target: "companies/#{company}/agents/#{slug}"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             :ok <- Support.validate_slug(slug, :agent),
             src = agent_dir(base, company, slug),
             :ok <- guard_exists_dir(src) do
          # C-099: stop the running agent + cancel its heartbeat BEFORE
          # the dir moves. Only reached after both slugs validate, so we
          # never feed an unsafe slug to the registry lookup.
          decommission_running_agent(company, slug, opts)
          do_retire_move(tx_id, src, base, company, slug, actor: actor, audit: audit)
        end
      end)

    case history_result do
      {:ok, result, _tx_id} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # C-099: terminate the agent's OTP sub-tree and unregister its
  # heartbeat. Best-effort: a `{:error, :not_found}` (idle/never-started)
  # or an `:exit` from an absent supervisor/scheduler (test harnesses
  # without a company tree) is fine — the goal is "if it's running, stop
  # it", not "fail the retire when nothing is running".
  defp decommission_running_agent(company, slug, opts) do
    stop_fun = Keyword.get(opts, :stop_agent_fun, &default_stop_agent/2)
    unregister_fun = Keyword.get(opts, :unregister_fun, &default_unregister/2)

    _ = safe_decommission_step("stop_agent", company, slug, fn -> stop_fun.(company, slug) end)

    _ =
      safe_decommission_step("unregister_heartbeat", company, slug, fn ->
        unregister_fun.(company, slug)
      end)

    :ok
  end

  # Best-effort, but no longer silent: an idle/absent agent (`:noproc`,
  # `:not_found`) is the expected no-op, while any OTHER rescued exception
  # or exit is logged (debug) with company+slug+step so a genuinely-failed
  # decommission is diagnosable rather than invisible (C-099 review).
  defp safe_decommission_step(step, company, slug, fun) do
    fun.()
  rescue
    e ->
      Logger.debug("retire #{company}/#{slug}: #{step} failed (rescued): #{Exception.message(e)}")

      :error
  catch
    :exit, reason ->
      Logger.debug("retire #{company}/#{slug}: #{step} exited: #{inspect(reason)}")
      :error
  end

  defp default_stop_agent(company, slug) do
    sup = Glorbo.Company.Supervisor.via(company, :agent_sup)
    Glorbo.Company.AgentSupervisor.stop_agent(sup, company, slug)
  end

  defp default_unregister(company, slug) do
    sched = Glorbo.Company.Supervisor.via(company, :scheduler)
    Glorbo.Company.Scheduler.unregister(sched, slug)
  end

  defp do_retire_move(tx_id, src, base, company, slug, opts) do
    actor = Keyword.fetch!(opts, :actor)
    audit = Keyword.fetch!(opts, :audit)

    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")
    archive_root = Path.join([base, "companies", company, "agents", ".archive"])
    dst_name = "#{slug}-#{ts}"
    dst = Path.join(archive_root, dst_name)
    archive_rel = Path.join(["agents", ".archive", dst_name])

    # Snapshot the tracked-scope files under the agent dir BEFORE
    # the rename so each one can be marked individually. The dest
    # is in excluded scope (`agents/.archive/...`) — only the
    # source-side deletions reach the history commit. The retire
    # event itself is the durable record; the archive subtree is
    # frozen.
    tracked_files = list_tracked_files_under(src, base)

    with :ok <- File.mkdir_p(archive_root),
         :ok <- File.rename(src, dst),
         :ok <- mark_each(tx_id, tracked_files),
         :ok <- emit_retire_audit(audit, company, slug, archive_rel, actor),
         :ok <- Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company)) do
      {:ok, %{archive_rel_path: archive_rel}}
    end
  end

  defp mark_each(_tx_id, []), do: :ok

  defp mark_each(tx_id, [path | rest]) do
    case Tx.mark_path(tx_id, path) do
      :ok -> mark_each(tx_id, rest)
    end
  end

  # Walk the agent dir collecting every tracked-scope file (e.g.,
  # `AGENT.md`, `SOUL.md`, `HEARTBEAT.md`, `memory/**`). Excluded-
  # scope subdirs (inbox/outbox/state/workspace/stdout.log) are
  # filtered out by `HomeHistory.tracked?/2`, so the resulting set
  # is exactly what would land in `Glorbo-Paths` after the retire.
  defp list_tracked_files_under(src, base) do
    if File.dir?(src) do
      src
      |> walk_files()
      |> Enum.filter(&HomeHistory.tracked?(&1, base))
    else
      []
    end
  end

  # C-040 / C-058: the agent's `workspace/` is bind-mounted `rw` into
  # the sandbox, so an agent can plant `workspace/loop -> .` or
  # `workspace/root -> /` before an operator retires it. `File.dir?`/
  # `File.regular?` follow symlinks, so the pre-rename snapshot walk
  # would recurse a symlink loop unboundedly or traverse a massive
  # host tree (`/proc`), exhausting CPU/memory and delaying the Tx
  # past its hard-cap. Use `:file.read_link_info` (lstat) so symlinks
  # are neither descended nor recorded, and cap recursion depth as a
  # belt-and-braces guard against any residual cycle.
  @max_walk_depth 32

  defp walk_files(path), do: walk_files(path, 0)

  defp walk_files(_path, depth) when depth > @max_walk_depth, do: []

  defp walk_files(path, depth) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(path, entry)

          case lstat_type(full) do
            :directory -> walk_files(full, depth + 1)
            :regular -> [full]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # lstat (no symlink follow). Returns the entry's own type — a
  # symlink reports `:symlink`, never the target's type.
  defp lstat_type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> type
      _ -> :error
    end
  end

  defp agent_dir(base, company, slug),
    do: Path.join([base, "companies", company, "agents", slug])

  defp resolve_workspace_path(agent_root, rel) do
    candidate = Path.expand(Path.join(agent_root, rel))

    if String.starts_with?(candidate, agent_root <> "/") do
      {:ok, candidate}
    else
      {:error, :invalid_path}
    end
  end

  # threatmodel H10: walk each segment from agent_root toward the
  # target; refuse any symlink along the way. :enoent on the leaf
  # is fine (new-file case).
  defp ensure_no_symlink_on_path(abs_path, root) do
    relative = Path.relative_to(abs_path, root)
    parts = Path.split(relative)

    Enum.reduce_while(parts, root, fn part, acc ->
      next = Path.join(acc, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_in_path}}
        {:ok, %File.Stat{}} -> {:cont, next}
        {:error, :enoent} -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _} = err -> err
      path when is_binary(path) -> :ok
    end
  end

  defp refuse_contract_write(rel) do
    if Path.basename(rel) in @contract_files,
      do: {:error, :contract_file},
      else: :ok
  end

  # Wave 27: O_EXCL create — refuses an existing file or a freshly-
  # planted symlink at `path` in one syscall. Use for the
  # zero-content seed write of `create_workspace_file/4`.
  defp exclusive_create(path) do
    case :file.open(path, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        :file.close(fd)

      {:error, _} = err ->
        err
    end
  end

  # Wave 27: random-suffix exclusive temp + atomic rename — replaces
  # the old `File.write/2` flow that left a TOCTOU window between
  # `ensure_no_symlink_on_path/2` and the actual write.
  #
  # C-055: the fresh exclusive temp is created at the process umask
  # (typically 0644). The in-place `File.write/2` it replaced preserved
  # the original inode's mode, so a 0600 workspace file was being
  # silently loosened to 0644 on rename. Capture the original mode
  # (when the file already exists) and chmod the temp to match before
  # the rename, defaulting to 0600 for new files.
  defp atomic_write(path, content) do
    rand = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = "#{path}.tmp-#{rand}"

    mode =
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o777)
        _ -> 0o600
      end

    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        write_result = :file.write(fd, content)
        :file.close(fd)

        case write_result do
          :ok ->
            with :ok <- File.chmod(tmp, mode),
                 :ok <- File.rename(tmp, path) do
              :ok
            else
              {:error, _} = err ->
                _ = File.rm(tmp)
                err
            end

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp guard_not_exists(abs_path) do
    if File.exists?(abs_path), do: {:error, :already_exists}, else: :ok
  end

  defp guard_exists(abs_path) do
    if File.exists?(abs_path), do: :ok, else: {:error, :not_found}
  end

  defp guard_exists_dir(abs_path) do
    if File.dir?(abs_path), do: :ok, else: {:error, :not_found}
  end

  defp emit_audit(audit, company, agent, action, rel_path, actor) do
    entry = %{
      actor: actor,
      action: action,
      target: Path.join(["agents", agent, rel_path]),
      company: company,
      agent: agent
    }

    Support.append_audit(audit, company, entry)
  end

  defp emit_trash_audit(audit, company, agent, rel_path, dest_rel, actor) do
    entry = %{
      actor: actor,
      action: "agent.file_trash",
      target: Path.join(["agents", agent, rel_path]),
      company: company,
      agent: agent,
      dest: Path.join(["agents", agent, dest_rel])
    }

    Support.append_audit(audit, company, entry)
  end

  defp emit_retire_audit(audit, company, agent, archive_rel, actor) do
    entry = %{
      actor: actor,
      action: "agent.retire",
      target: Path.join(["agents", agent]),
      company: company,
      agent: agent,
      dest: archive_rel
    }

    Support.append_audit(audit, company, entry)
  end
end
