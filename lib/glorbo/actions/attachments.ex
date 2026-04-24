defmodule Glorbo.Actions.Attachments do
  @moduledoc """
  Task-attachment ingest operations (GEP-36).

  Single public function today: `ingest/6` — copy a single
  uploaded file into `projects/<p>/attachments/<task_id>/<safe-name>`
  and return the task-body-relative path for the attachment list.

  Separate from `Glorbo.Actions.Tasks` because attachments can
  land before the task file exists (LiveView's upload flow
  pre-reserves a task id so uploads can stream into
  `attachments/<reserved-id>/` while the form is still being
  filled out).

  ## Contract

    * Returns `{:ok, rel_path}` or `{:error, reason}`.
    * `opts` requires `:actor`.
    * Emits `attachment.upload` audit on success.
    * Creates the destination directory idempotently
      (`File.mkdir_p/1`).
  """

  alias Glorbo.Company.AuditLog

  @slug_re ~r/\A[a-z0-9][a-z0-9-]*\z/
  @task_id_re ~r/\A[a-z0-9][a-z0-9-]*\z/

  @type ingest_opts ::
          [actor: String.t(), base: Path.t(), audit: atom()]

  @doc """
  Copy a single uploaded file into the canonical attachment
  location.

    * `tmp_path` is the absolute path of the upload's temp file
      (whatever Phoenix LiveView hands you in the
      `consume_uploaded_entries` callback).
    * `client_name` is the original filename as claimed by the
      client. This function sanitizes it before writing
      (replaces anything outside `[A-Za-z0-9._-]` with `_`,
      strips leading dots, falls back to `"file"` on empty).

  Returns `{:ok, "attachments/<task_id>/<safe-name>"}` — a path
  relative to the project root, suitable for the task body's
  attachment list.
  """
  @spec ingest(String.t(), String.t(), String.t(), Path.t(), String.t(), ingest_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def ingest(company, project, task_id, tmp_path, client_name, opts \\ [])
      when is_binary(company) and is_binary(project) and is_binary(task_id) and
             is_binary(tmp_path) and is_binary(client_name) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- validate_slug(company, :company),
         :ok <- validate_slug(project, :project),
         :ok <- validate_task_id(task_id),
         safe = sanitize_filename(client_name),
         dest_dir =
           Path.join([base, "companies", company, "projects", project, "attachments", task_id]),
         :ok <- File.mkdir_p(dest_dir),
         dest = Path.join(dest_dir, safe),
         :ok <- File.cp(tmp_path, dest),
         rel = Path.join(["attachments", task_id, safe]),
         :ok <- emit_upload_audit(audit, company, project, task_id, rel, client_name, safe, actor) do
      {:ok, rel}
    end
  end

  @doc false
  # Sanitizer lifted verbatim from the pre-migration
  # KanbanLive.sanitize_filename/1 so upload behavior matches.
  def sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[^\w.\-]/u, "_")
    |> String.trim_leading(".")
    |> case do
      "" -> "file"
      ok -> ok
    end
  end

  defp validate_slug(slug, kind) when is_binary(slug) do
    if Regex.match?(@slug_re, slug), do: :ok, else: {:error, {:invalid_slug, kind, slug}}
  end

  defp validate_task_id(id) when is_binary(id) do
    if Regex.match?(@task_id_re, id), do: :ok, else: {:error, {:invalid_task_id, id}}
  end

  defp emit_upload_audit(audit, company, project, task_id, rel_path, client_name, safe, actor) do
    entry =
      %{
        actor: actor,
        action: "attachment.upload",
        target: "projects/#{project}/#{rel_path}",
        company: company,
        project: project,
        task_id: task_id,
        filename: safe
      }
      |> put_detail("client_name", client_name)

    append_audit(audit, company, entry)
  end

  # Audit routing — same pattern as Actions.Tasks.append_audit/3.
  defp append_audit(AuditLog, company, entry), do: safe_append_for(company, entry)

  defp append_audit(target, _company, entry) when is_atom(target) or is_pid(target),
    do: AuditLog.append(target, entry)

  defp append_audit(other, _company, entry), do: AuditLog.append(other, entry)

  defp safe_append_for(company, entry) do
    AuditLog.append_for(company, entry)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {{:noproc, _}, _} -> :ok
  end

  defp put_detail(map, _key, nil), do: map
  defp put_detail(map, _key, ""), do: map
  defp put_detail(map, key, value), do: Map.put(map, key, to_string(value))

  defp default_base, do: Glorbo.Filesystem.Hierarchy.default_root()
end
