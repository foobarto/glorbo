defmodule Glorbo.Actions.Channels do
  @moduledoc """
  Channel mutation operations (GEP-36).

  Two functions:

    * `create/3` — materialize a fresh channel log at
      `companies/<co>/channels/<slug>.md` with canonical header.
    * `archive/3` — move a channel into
      `companies/<co>/channels/.archive/<slug>.md`. Rejects the
      canonical `general` channel and any DM (`dm-director--*`).

  ## Contract

    * Returns `{:ok, result}` or `{:error, reason}`.
    * `opts` requires `:actor`.
    * Emits `channel.create` / `channel.archive` audit entries.
  """

  alias Glorbo.Company.AuditLog

  @slug_re ~r/\A[a-z0-9][a-z0-9-]*\z/

  @type create_opts :: [actor: String.t(), base: Path.t(), audit: atom()]
  @type archive_opts :: [actor: String.t(), base: Path.t(), audit: atom()]

  @doc """
  Materialize a new channel log.

  Returns `{:error, :already_exists}` when the target file is
  already present. Rejects invalid slugs (only lowercase
  alphanumerics and dashes, not leading with `-`).
  """
  @spec create(String.t(), String.t(), create_opts()) ::
          {:ok, %{rel_path: String.t(), abs_path: String.t()}} | {:error, term()}
  def create(company, channel, opts \\ [])
      when is_binary(company) and is_binary(channel) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- validate_slug(company, :company),
         :ok <- validate_slug(channel, :channel),
         abs = channel_path(base, company, channel),
         :ok <- guard_not_exists(abs),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, render_header(channel)),
         :ok <- emit_create_audit(audit, company, channel, actor) do
      {:ok, %{rel_path: "channels/#{channel}.md", abs_path: abs}}
    end
  end

  @doc """
  Move a channel into the `.archive/` subdirectory.

  Refuses to archive `general` and DMs (`dm-director--*`): those
  are load-bearing for the Director's chat flow.
  """
  @spec archive(String.t(), String.t(), archive_opts()) ::
          {:ok, %{dest_rel_path: String.t()}} | {:error, term()}
  def archive(company, channel, opts \\ [])
      when is_binary(company) and is_binary(channel) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- validate_slug(company, :company),
         :ok <- validate_slug(channel, :channel),
         :ok <- guard_archivable(channel),
         src = channel_path(base, company, channel),
         :ok <- guard_exists(src),
         archive_dir = archive_dir_path(base, company),
         dst = Path.join(archive_dir, "#{channel}.md"),
         :ok <- File.mkdir_p(archive_dir),
         :ok <- File.rename(src, dst),
         dest_rel = "channels/.archive/#{channel}.md",
         :ok <- emit_archive_audit(audit, company, channel, dest_rel, actor) do
      {:ok, %{dest_rel_path: dest_rel}}
    end
  end

  defp render_header(channel) do
    """
    ---
    kind: channel-log/v1
    channel: #{channel}
    ---
    # ##{channel}

    """
  end

  defp channel_path(base, company, channel),
    do: Path.join([base, "companies", company, "channels", "#{channel}.md"])

  defp archive_dir_path(base, company),
    do: Path.join([base, "companies", company, "channels", ".archive"])

  defp guard_not_exists(abs) do
    if File.exists?(abs), do: {:error, :already_exists}, else: :ok
  end

  defp guard_exists(abs) do
    if File.exists?(abs), do: :ok, else: {:error, :not_found}
  end

  # `general` = Director's catch-all + chat-drawer backing channel.
  # `dm-director--*` = DM threads owned by their counterparties.
  # Both are load-bearing for the Director UX and must not be
  # archived through this API.
  defp guard_archivable("general"), do: {:error, :not_archivable}

  defp guard_archivable(channel) when is_binary(channel) do
    if String.starts_with?(channel, "dm-director--"),
      do: {:error, :not_archivable},
      else: :ok
  end

  defp guard_archivable(_), do: {:error, :not_archivable}

  defp validate_slug(slug, kind) when is_binary(slug) do
    if Regex.match?(@slug_re, slug), do: :ok, else: {:error, {:invalid_slug, kind, slug}}
  end

  defp emit_create_audit(audit, company, channel, actor) do
    entry = %{
      actor: actor,
      action: "channel.create",
      target: "channels/#{channel}.md",
      company: company,
      channel: channel
    }

    append_audit(audit, company, entry)
  end

  defp emit_archive_audit(audit, company, channel, dest_rel, actor) do
    entry = %{
      actor: actor,
      action: "channel.archive",
      target: "channels/#{channel}.md",
      company: company,
      channel: channel,
      dest: dest_rel
    }

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

  defp default_base, do: Glorbo.Filesystem.Hierarchy.default_root()
end
