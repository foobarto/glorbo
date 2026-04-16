defmodule Glorbo.CLI.Audit do
  @moduledoc """
  Thin wrapper around `Glorbo.Company.AuditLog` for `cli.<verb>.*` events
  (Plan 05-02).

  Every mutating CLI verb emits `cli.<verb>.start` and `cli.<verb>.complete`
  entries to `audit/_system/YYYY-MM.jsonl`. Failures (AuditLog GenServer
  not running, disk full, etc.) MUST NOT block the CLI — the audit log is
  append-only (CLAUDE.md invariant) but the CLI itself must still make
  progress on an unhealthy install.

  Hence every call is wrapped in a `try/rescue/catch` that swallows both
  exceptions (`ArgumentError`, `File.Error`) and exits (`GenServer.call/2`
  on a dead/absent process exits with `:noproc`).
  """
  alias Glorbo.Company.AuditLog

  @type verb :: atom() | String.t()

  @doc """
  Emit `cli.<verb>.<phase>` for a CLI action.

  `phase` is typically `"start"` or `"complete"`. `detail` is merged into
  the audit entry's `detail:` JSON payload.
  """
  @spec emit(verb(), String.t(), map()) :: :ok
  def emit(verb, phase \\ "start", detail \\ %{})
      when (is_atom(verb) or is_binary(verb)) and is_binary(phase) do
    entry = %{
      company: "_system",
      actor: "cli",
      action: "cli.#{verb}.#{phase}",
      target: to_string(verb),
      detail: detail
    }

    try do
      AuditLog.append(entry)
    rescue
      _ -> :ok
    catch
      # GenServer.call/2 on a dead/absent process exits with :noproc —
      # swallow and continue so the CLI keeps flowing on a cold install.
      :exit, _ -> :ok
    end

    :ok
  end
end
