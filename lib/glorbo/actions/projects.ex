defmodule Glorbo.Actions.Projects do
  @moduledoc """
  Project mutation operations (GEP-36).

  Two functions:

    * `ensure_stub/3` — write `projects/<project>/project.md` with
      a minimal kind-and-slug skeleton if it is missing. Idempotent:
      returns `{:ok, :exists}` when the file is already present.

    * `update/4` — atomic edit of the frontmatter fields
      (`name`, `icon`, `description`), preserving the body.

  Both functions enforce the **threatmodel M19** symlink-swap guard
  (`lstat` refuses anything non-regular at either the target or the
  `.tmp` path) so an agent-planted symlink cannot redirect
  `File.write`/`File.rename` to an arbitrary host path.

  ## Contract

    * Returns `{:ok, result}` or `{:error, reason}`.
    * `opts` requires `:actor`.
    * Emits a `Glorbo.Company.AuditLog` entry before returning on
      success. `ensure_stub` emits only when a new file lands.
  """

  alias Glorbo.Actions.Support
  alias Glorbo.Company.AuditLog
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

  @type ensure_stub_opts ::
          [actor: String.t(), base: Path.t(), audit: atom()]

  @type update_meta :: %{
          optional(:name) => String.t() | nil,
          optional(:icon) => String.t() | nil,
          optional(:description) => String.t() | nil
        }

  @type update_opts ::
          [actor: String.t(), base: Path.t(), audit: atom()]

  @doc """
  Ensure `projects/<project>/project.md` exists.

  * If the file is present + regular → `{:ok, :exists}`, no write.
  * If the file is missing → write skeleton frontmatter, emit
    `project.create` audit, return `{:ok, :created}`.
  * If the file is a symlink or other non-regular type → refuse
    with `{:error, :not_a_regular_file}`.
  """
  @spec ensure_stub(String.t(), String.t(), ensure_stub_opts()) ::
          {:ok, :exists | :created} | {:error, term()}
  def ensure_stub(company, project, opts \\ [])
      when is_binary(company) and is_binary(project) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "project.create",
      target: "companies/#{company}/projects/#{project}/project.md"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             :ok <- Support.validate_slug(project, :project),
             abs_path = project_md_path(base, company, project),
             :ok <- ensure_writable(abs_path) do
          create_or_skip_stub(tx_id, abs_path, base, company, project, actor, audit)
        end
      end)

    case history_result do
      # `:exists` means the file was already on disk — no diff, no
      # commit. The Tx auto-flushes as a clean no-op.
      {:ok, :exists, _tx_id} -> {:ok, :exists}
      {:ok, :created, _tx_id} -> {:ok, :created}
      {:error, _} = err -> err
    end
  end

  @doc """
  Atomic edit of `projects/<project>/project.md` frontmatter.

  Preserves the body after the frontmatter terminator. Writes via
  `tmp + rename`; on any failure after the temp file is created,
  best-effort-removes it.
  """
  @spec update(String.t(), String.t(), update_meta(), update_opts()) ::
          {:ok, %{abs_path: String.t()}} | {:error, term()}
  def update(company, project, meta, opts \\ [])
      when is_binary(company) and is_binary(project) and is_map(meta) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &Support.default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)
    path = project_md_path(base, company, project)
    tmp = path <> ".tmp"

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "project.update",
      target: "companies/#{company}/projects/#{project}/project.md"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- Support.validate_slug(company, :company),
             :ok <- Support.validate_slug(project, :project),
             :ok <- ensure_writable(path),
             :ok <- ensure_writable(tmp),
             {:ok, content} <- File.read(path),
             new_content = render_new_content(content, meta),
             :ok <- atomic_write(tmp, path, new_content),
             :ok <- Tx.mark_path(tx_id, path),
             :ok <- emit_update_audit(audit, company, project, actor, meta),
             :ok <- Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company)) do
          {:ok, %{abs_path: path}}
        end
      end)

    case history_result do
      {:ok, result, _tx_id} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  defp create_or_skip_stub(tx_id, abs_path, base, company, project, actor, audit) do
    if File.exists?(abs_path) do
      {:ok, :exists}
    else
      stub = "---\nkind: project/v1\nslug: #{project}\n---\n"

      with :ok <- File.write(abs_path, stub),
           :ok <- Tx.mark_path(tx_id, abs_path),
           :ok <- emit_create_audit(audit, company, project, actor),
           :ok <- Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(base, company)) do
        {:ok, :created}
      end
    end
  end

  defp render_new_content(content, meta) do
    {_fm, body} = split_frontmatter(content)
    "---\n" <> render_fm(meta) <> "\n---\n" <> (body || "")
  end

  defp atomic_write(tmp, path, content) do
    with :ok <- File.write(tmp, content, [:sync]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        err
    end
  end

  # threatmodel M19: lstat-refuse any symlink at either the target
  # or the .tmp path. :enoent is fine — the file hasn't been
  # created yet, and a non-existent path can't be a swapped
  # symlink.
  defp ensure_writable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_a_regular_file}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_md_path(base, company, project),
    do: Path.join([base, "companies", company, "projects", project, "project.md"])

  defp split_frontmatter(content) do
    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", fm, body] -> {fm, body}
      _ -> {"", content}
    end
  end

  defp render_fm(meta) do
    [
      {"name", Map.get(meta, :name)},
      {"icon", Map.get(meta, :icon)},
      {"description", Map.get(meta, :description)}
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.map_join("\n", fn {k, v} -> ~s(#{k}: "#{escape(v)}") end)
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
    |> String.replace("\n", " ")
  end

  defp emit_create_audit(audit, company, project, actor) do
    entry = %{
      actor: actor,
      action: "project.create",
      target: "projects/#{project}/project.md",
      company: company,
      project: project
    }

    Support.append_audit(audit, company, entry)
  end

  defp emit_update_audit(audit, company, project, actor, meta) do
    entry =
      %{
        actor: actor,
        action: "project.update",
        target: "projects/#{project}/project.md",
        company: company,
        project: project
      }
      |> Support.put_detail("name", Map.get(meta, :name))
      |> Support.put_detail("icon", Map.get(meta, :icon))
      |> Support.put_detail("description", Map.get(meta, :description))

    Support.append_audit(audit, company, entry)
  end
end
