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

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog

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
         :ok <- File.write(abs_path, ""),
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
         :ok <- File.write(abs_path, content),
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

  @doc """
  Retire an agent by moving its whole dir to
  `agents/.archive/<slug>-<ts>/`. Call sites SHOULD stop any in-flight
  dispatch first; this function does not touch the OTP tree.
  """
  @spec retire(String.t(), String.t(), opts()) ::
          {:ok, %{archive_rel_path: String.t()}} | {:error, term()}
  def retire(company, slug, opts \\ [])
      when is_binary(company) and is_binary(slug) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- Support.validate_slug(company, :company),
         :ok <- Support.validate_slug(slug, :agent),
         src = agent_dir(base, company, slug),
         :ok <- guard_exists_dir(src) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")
      archive_root = Path.join([base, "companies", company, "agents", ".archive"])
      dst_name = "#{slug}-#{ts}"
      dst = Path.join(archive_root, dst_name)
      archive_rel = Path.join(["agents", ".archive", dst_name])

      with :ok <- File.mkdir_p(archive_root),
           :ok <- File.rename(src, dst),
           :ok <- emit_retire_audit(audit, company, slug, archive_rel, actor) do
        {:ok, %{archive_rel_path: archive_rel}}
      end
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
