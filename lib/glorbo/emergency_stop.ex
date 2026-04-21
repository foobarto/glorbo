defmodule Glorbo.EmergencyStop do
  @moduledoc """
  Company-scoped emergency kill switch (T2-C).

  When engaged, two things happen:

    1. Every currently-running `Agent.Server` dispatch for that
       company is stopped (`stop_inflight/1` fires SIGKILL at the
       Task and marks the agent `last_exit_status =
       "stopped_by_director"`).
    2. `Glorbo.Agent.Dispatch.execute/3` refuses new dispatches with
       `{:error, :emergency_stopped}` while the sentinel is present.

  The sentinel is a single markdown file:
  `companies/<co>/state/emergency-stop.md`. Its presence is the
  source of truth — the module is stateless between calls; a
  restart re-reads the sentinel. The director clears the stop by
  calling `clear/2` (or by removing the file by hand; the app
  will re-enable dispatch on the next `engaged?/2` check).

  Every transition emits an audit event: `emergency.engage` on
  engage, `emergency.clear` on clear.
  """

  alias Glorbo.Company.AuditLog

  @sentinel_filename "emergency-stop.md"

  @type opts :: [
          base: Path.t(),
          audit_fun: (String.t(), map() -> any()),
          kill_fun: (String.t() -> any()),
          actor: String.t(),
          reason: String.t() | nil
        ]

  @doc """
  Engage the emergency stop for `company`.

  Writes the sentinel file with the `actor`, `reason`, and timestamp
  in a YAML frontmatter block. Returns `:ok` even if the sentinel
  already exists — re-engaging is idempotent and re-runs the kill
  pass so any newly-started agents get caught.
  """
  @spec engage(String.t(), opts()) :: :ok | {:error, term()}
  def engage(company, opts \\ []) when is_binary(company) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    actor = Keyword.get(opts, :actor, "director")
    reason = Keyword.get(opts, :reason)
    kill_fun = Keyword.get(opts, :kill_fun, &kill_running_agents/1)
    audit_fun = Keyword.get(opts, :audit_fun, fn ^company, entry -> AuditLog.append(entry) end)

    path = sentinel_path(base, company)
    File.mkdir_p!(Path.dirname(path))

    content = sentinel_body(actor, reason)

    with :ok <- File.write(path, content, [:sync]) do
      _ = kill_fun.(company)

      _ =
        audit_fun.(company, %{
          company: company,
          actor: actor,
          action: "emergency.engage",
          target: "state/#{@sentinel_filename}",
          reason: reason || ""
        })

      :ok
    end
  end

  @doc """
  Clear the emergency stop for `company`. Removes the sentinel and
  emits an audit event. Returns `:ok` even when the sentinel was
  already absent — clearing is idempotent.
  """
  @spec clear(String.t(), opts()) :: :ok
  def clear(company, opts \\ []) when is_binary(company) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    actor = Keyword.get(opts, :actor, "director")
    audit_fun = Keyword.get(opts, :audit_fun, fn ^company, entry -> AuditLog.append(entry) end)

    path = sentinel_path(base, company)
    _ = File.rm(path)

    _ =
      audit_fun.(company, %{
        company: company,
        actor: actor,
        action: "emergency.clear",
        target: "state/#{@sentinel_filename}"
      })

    :ok
  end

  @doc """
  Is the emergency stop currently engaged for `company`?
  """
  @spec engaged?(String.t(), opts()) :: boolean()
  def engaged?(company, opts \\ []) when is_binary(company) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    File.exists?(sentinel_path(base, company))
  end

  @doc """
  Read the sentinel frontmatter for display (actor + reason + ts).
  Returns `%{}` when the sentinel is missing or malformed.
  """
  @spec read_sentinel(String.t(), opts()) :: map()
  def read_sentinel(company, opts \\ []) when is_binary(company) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    path = sentinel_path(base, company)

    with {:ok, content} <- File.read(path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      fm
    else
      _ -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp sentinel_path(base, company),
    do: Path.join([base, "companies", company, "state", @sentinel_filename])

  defp sentinel_body(actor, reason) do
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    reason_line = if reason, do: "reason: #{yaml_escape(reason)}\n", else: ""

    """
    ---
    kind: emergency-stop/v1
    engaged_by: #{actor}
    engaged_at: #{ts}
    #{reason_line}---

    # Emergency stop engaged

    All agent dispatch for this company is halted. Delete this
    file — or click "Clear" in the UI — to resume normal
    operation.
    """
  end

  defp yaml_escape(value) when is_binary(value) do
    if String.contains?(value, ["\n", ":", "#", "\""]) do
      "\"" <> String.replace(value, "\"", "\\\"") <> "\""
    else
      value
    end
  end

  # Stop every running Agent.Server Task for this company.
  defp kill_running_agents(company) do
    registry = Glorbo.Agent.Registry

    Registry.select(
      registry,
      [{{{:agent_server, :"$1", :"$2"}, :"$3", :_}, [{:==, :"$1", company}], [:"$3"]}]
    )
    |> Enum.each(fn pid ->
      try do
        Glorbo.Agent.Server.stop_inflight(pid)
      catch
        :exit, _ -> :ok
      end
    end)
  end
end
