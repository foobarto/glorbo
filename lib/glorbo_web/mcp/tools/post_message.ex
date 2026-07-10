defmodule GlorboWeb.MCP.Tools.PostMessage do
  @moduledoc """
  MCP tool: `glorbo.post_message` (GEP-29 wave c.1).

  Appends a message to a channel. Calls
  `Glorbo.Actions.post_message/4` so @mentions wake agents and
  the channel-rotation post-hook runs identically to the LV path.
  Actor is `mcp:<client>` (GEP-29 D4) — appears in the message
  header (`## <ts> | mcp:<client>`) and on the `chat.post` audit
  event.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Actions
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.post_message"

  @impl true
  def description,
    do: """
    Post a message to a chat channel. Body is written verbatim
    after a `## <iso-ts> | mcp:<client>` header so the message is
    visibly distinct from Director posts. @mentions in the body
    wake the named agents. Emits chat.post on the audit log.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "channel" => %{"type" => "string"},
        "body" => %{"type" => "string"}
      },
      "required" => ["company", "channel", "body"],
      "additionalProperties" => false
    }

  @impl true
  def call(
        %{"company" => company, "channel" => channel, "body" => body},
        context
      )
      when is_binary(company) and is_binary(channel) and is_binary(body) do
    with :ok <- Args.require_slugs(company: company, channel: channel),
         :ok <- require_nonempty(body) do
      do_call(company, channel, body, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, channel, body, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    actor = mcp_actor(context)

    case Actions.post_message(
           company,
           channel,
           body,
           Keyword.merge([base: base, actor: actor], audit_opt(context))
         ) do
      :ok ->
        {:ok, %{"channel" => channel, "actor" => actor}}

      {:error, reason} ->
        {:error, {:post_failed, reason}}
    end
  end

  defp require_nonempty(s) when is_binary(s) do
    if String.trim(s) == "", do: {:error, :empty_body}, else: :ok
  end

  defp mcp_actor(context) do
    client = Map.get(context, :client, "unknown")
    "mcp:#{client}"
  end

  defp audit_opt(%{audit: audit}) when not is_nil(audit), do: [audit: audit]
  defp audit_opt(_), do: []
end
