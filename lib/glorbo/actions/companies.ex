defmodule Glorbo.Actions.Companies do
  @moduledoc """
  Company mutation operations (GEP-36).

  Atomic writes to `companies/<slug>/company.md` go through
  `update/3`. Callers (LiveView, MCP, shell) invoke this directly —
  no raw `File.*!` writes in frontend handlers.

  ## Contract

    * Returns `{:ok, result}` or `{:error, reason}`.
    * `opts` requires `:actor`. Missing `:actor` raises
      `ArgumentError` at the boundary.
    * Emits a `Glorbo.Company.AuditLog` entry before returning on
      success. Matches the routing used by `Glorbo.Actions.Tasks`:
      explicit test sinks land through `AuditLog.append/2`; the
      production default falls back to `append_for/2`.
  """

  alias Glorbo.Company.AuditLog

  @slug_re ~r/\A[a-z0-9][a-z0-9-]*\z/
  @name_max_bytes 200

  @type update_params :: %{optional(String.t()) => any()}
  @type update_opts ::
          [
            actor: String.t(),
            base: Path.t(),
            audit: atom()
          ]
  @type update_result :: %{abs_path: String.t(), rel_path: String.t()}

  @doc """
  Write `companies/<company>/company.md` atomically.

  Validates slug + name + optional budget, builds canonical YAML
  frontmatter, writes via `write + rename`, then emits the
  `company.update` audit entry.

  ### Params (string-keyed map)

    * `"name"` — required, non-empty after trim.
    * `"description"` — optional.
    * `"icon"` — optional.
    * `"monthly_usd"` — optional; blank or unparseable → no budget
      block emitted.
    * `"body"` — optional free-text body (everything after the YAML
      frontmatter).

  ### Options

    * `:actor` (required) — who performed the update.
    * `:base` — filesystem root (default `~/.glorbo`).
    * `:audit` — AuditLog target (default global).
  """
  @spec update(String.t(), update_params(), update_opts()) ::
          {:ok, update_result()} | {:error, term()}
  def update(company, params, opts \\ [])
      when is_binary(company) and is_map(params) and is_list(opts) do
    actor = opts |> Keyword.fetch!(:actor) |> to_string()
    base = Keyword.get_lazy(opts, :base, &default_base/0)
    audit = Keyword.get(opts, :audit, AuditLog)

    with :ok <- validate_slug(company),
         {:ok, fields} <- validate_params(company, params),
         abs_path = Path.join([base, "companies", company, "company.md"]),
         content = render(fields, params),
         :ok <- atomic_write(abs_path, content),
         :ok <- emit_update_audit(audit, company, actor, fields) do
      {:ok, %{abs_path: abs_path, rel_path: "company.md"}}
    end
  end

  defp atomic_write(path, content) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp validate_slug(slug) do
    if Regex.match?(@slug_re, slug), do: :ok, else: {:error, {:invalid_slug, slug}}
  end

  defp validate_params(slug, params) do
    name = params |> Map.get("name", "") |> to_string() |> String.trim()

    cond do
      name == "" ->
        {:error, :name_required}

      byte_size(name) > @name_max_bytes ->
        {:error, :name_too_long}

      true ->
        fields = %{
          slug: slug,
          name: name,
          description: params |> Map.get("description", "") |> to_string() |> String.trim(),
          icon: params |> Map.get("icon", "") |> to_string() |> String.trim(),
          monthly_usd:
            params
            |> Map.get("monthly_usd", "")
            |> to_string()
            |> String.trim()
            |> parse_monthly()
        }

        {:ok, fields}
    end
  end

  defp parse_monthly(""), do: nil

  defp parse_monthly(raw) do
    case Float.parse(raw) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp render(fields, params) do
    body = params |> Map.get("body", "") |> to_string() |> String.trim_trailing()
    yaml = render_yaml(fields)
    "---\n" <> yaml <> "---\n\n" <> body <> "\n"
  end

  # Hand-rolled YAML — we control every string, so quoting is
  # trivial. Same pattern as TaskDefinition.write_frontmatter and
  # the pre-extraction CompanyLive helper.
  defp render_yaml(%{
         slug: slug,
         name: name,
         description: desc,
         icon: icon,
         monthly_usd: monthly
       }) do
    scalars =
      [
        {"kind", "company/v1"},
        {"slug", slug},
        {"name", name},
        {"description", desc},
        {"icon", icon}
      ]
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Enum.map_join(fn {k, v} -> "#{k}: #{yaml_string(v)}\n" end)

    budget =
      case monthly do
        nil -> ""
        n -> "budget:\n  monthly_usd: #{Float.round(n * 1.0, 2)}\n"
      end

    scalars <> budget
  end

  defp yaml_string(s) do
    if String.contains?(s, [":", "#", "[", "]", "\"", "'", "\n"]) do
      ~s("#{String.replace(s, "\"", "\\\"")}")
    else
      s
    end
  end

  defp emit_update_audit(audit, company, actor, fields) do
    entry =
      %{
        actor: actor,
        action: "company.update",
        target: "company.md",
        company: company,
        name: fields.name
      }
      |> put_detail("description", fields.description)
      |> put_detail("icon", fields.icon)
      |> put_detail("monthly_usd", fields.monthly_usd)

    append_audit(audit, company, entry)
  end

  # Audit routing — same logic as Actions.Tasks.append_audit/3.
  # The production default (`AuditLog` module atom) routes through
  # `append_for/2` which is per-company-named; explicit test sinks
  # use `append/2` directly; the bare-module LiveCase AuditLog also
  # works. If no audit process is up, swallow `:noproc` — the write
  # already landed.
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
