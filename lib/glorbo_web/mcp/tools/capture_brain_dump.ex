defmodule GlorboWeb.MCP.Tools.CaptureBrainDump do
  @moduledoc """
  MCP tool: `glorbo.capture_brain_dump` (GEP-29 wave c.1).

  Appends a capture to the company's daily brain-dump file via
  `Glorbo.BrainDump.capture/4`. Same entry point the BrainDump
  LV uses.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.BrainDump
  alias Glorbo.Company.AuditLog
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.capture_brain_dump"

  @impl true
  def description,
    do: """
    Append a brain-dump capture to today's company file
    (brain-dump/<YYYY-MM-DD>.md). Body is trimmed and written
    verbatim as a new `## <time> — <derived title>` section.
    Returns the ts + derived title.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "body" => %{"type" => "string"}
      },
      "required" => ["company", "body"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company, "body" => body}, context)
      when is_binary(company) and is_binary(body) do
    with :ok <- Args.require_slug(company, :company) do
      do_call(company, body, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, body, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    case BrainDump.capture(base, company, body) do
      {:ok, entry} ->
        # GEP-29 D4: every MCP-driven write emits an audit event the
        # same way the LV-driven path does. BrainDumpLive calls
        # `AuditLog.append_for/2` after `BrainDump.capture/3`; this
        # tool mirrors that with `mcp:<client>` as the actor so the
        # audit trail is consistent regardless of surface.
        _ =
          AuditLog.append_for(company, %{
            actor: mcp_actor(context),
            action: "braindump.capture",
            target: entry.ts,
            detail: %{title: entry.title, day: entry.day, source: "mcp"}
          })

        {:ok,
         %{
           "ts" => entry.ts,
           "title" => entry.title,
           "day" => Map.get(entry, :day)
         }}

      {:error, reason} ->
        {:error, {:capture_failed, reason}}
    end
  end

  defp mcp_actor(context) do
    client = Map.get(context, :client, "unknown")
    "mcp:#{client}"
  end
end
