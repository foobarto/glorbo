defmodule GlorboWeb.MCP.Tools.CreateChannel do
  @moduledoc """
  MCP tool: `glorbo.create_channel` (GEP-29 wave c.2).

  Initializes an empty chat channel at
  `companies/<co>/channels/<channel>.md` with the canonical
  `channel-log/v1` frontmatter + `# #<channel>` header. Same on-disk
  shape the ChannelLive "create channel" handler produces. Returns
  success if the file already exists (idempotent).
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Actions.Channels
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.create_channel"

  @impl true
  def description,
    do: """
    Create a new chat channel. Writes the initial
    channels/<channel>.md with `kind: channel-log/v1` frontmatter
    and a `# #<channel>` heading. If the file already exists the
    tool returns status="existed" without modifying it.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "channel" => %{"type" => "string"}
      },
      "required" => ["company", "channel"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company, "channel" => channel}, context)
      when is_binary(company) and is_binary(channel) do
    with :ok <- Args.require_slugs(company: company, channel: channel) do
      do_call(company, channel, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, channel, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    opts =
      [actor: mcp_actor(context), base: base]
      |> then(fn opts ->
        if context[:audit], do: Keyword.put(opts, :audit, context[:audit]), else: opts
      end)

    case Channels.create(company, channel, opts) do
      {:ok, _result} -> {:ok, %{"channel" => channel, "status" => "created"}}
      {:error, :already_exists} -> {:ok, %{"channel" => channel, "status" => "existed"}}
      {:error, :company_not_found} -> {:error, {:company_not_found, company}}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp mcp_actor(context), do: "mcp:#{Map.get(context, :client, "unknown")}"
end
