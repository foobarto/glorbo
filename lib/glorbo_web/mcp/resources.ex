defmodule GlorboWeb.MCP.Resources do
  @moduledoc """
  MCP resource catalog + snapshot reader (GEP-29 wave d.1).

  Resources are the MCP concept for "read-only data streams the
  client can subscribe to." Wave (d.1) ships only the list + read
  side — concrete URIs and their JSON-snapshot payloads. Streaming
  subscriptions (`resources/subscribe` + SSE push) are deferred to
  wave (d.2).

  ## URI scheme

  All resources use the `glorbo://` scheme to keep them distinct
  from file:// and https:// resources an MCP client might already
  handle. Per-resource URIs:

    * `glorbo://audit/<company>`
    * `glorbo://chat/<company>/<channel>`
    * `glorbo://approvals/<company>`
    * `glorbo://proposals/<company>`

  Agent stdout (`glorbo://agent/<company>/<slug>/stdout`) is
  deferred to wave (d.2) — stdout is a natural fit for streaming
  and doesn't have a clean "snapshot" read.

  ## Error codes

  Per MCP spec §"Error Handling":

    * `-32002` — resource not found (unknown URI, unknown company/
      channel/agent).
    * `-32603` — internal error (filesystem read failure, etc.).
  """

  alias GlorboWeb.MCP.Tools.GetChannel
  alias GlorboWeb.MCP.Tools.ListPendingApprovals
  alias GlorboWeb.MCP.Tools.ListProposals
  alias GlorboWeb.MCP.Tools.QueryAudit
  alias GlorboWeb.Slug

  @uri_scheme "glorbo"

  @doc """
  Public helper for modules that need to apply the same slug-gate
  to URI path segments (e.g. `GlorboWeb.MCP.Session` when parsing
  subscribe targets).
  """
  @spec valid_segment?(String.t()) :: boolean()
  def valid_segment?(segment), do: Slug.valid?(segment)

  @doc """
  Enumerate every concrete resource URI this server currently
  knows about. Walks `<base>/companies/` once; emits per-company
  audit/approvals/proposals URIs + per-channel chat URIs.

  Not paginated in wave (d.1) — a single-host Glorbo with a handful
  of companies fits well under any reasonable default cursor size.
  If a deployment ever grows beyond that, add cursor support here.
  """
  @spec list(map()) :: [map()]
  def list(context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    companies_dir = Path.join(base, "companies")

    case File.ls(companies_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(fn name ->
          Slug.valid?(name) and File.dir?(Path.join(companies_dir, name))
        end)
        |> Enum.flat_map(fn slug -> resources_for_company(base, slug) end)

      _ ->
        []
    end
  end

  @doc """
  URI templates — the patterns clients can use to construct
  resource URIs without enumerating. Useful for auto-complete and
  for references to resources that don't yet exist (e.g. before an
  agent has ever run).
  """
  @spec templates() :: [map()]
  def templates do
    [
      %{
        "uriTemplate" => "#{@uri_scheme}://audit/{company}",
        "name" => "company-audit",
        "description" => "Audit log for a company (JSONL, newest-first on read)",
        "mimeType" => "application/json"
      },
      %{
        "uriTemplate" => "#{@uri_scheme}://chat/{company}/{channel}",
        "name" => "chat-channel",
        "description" => "Recent messages on a chat channel (newest-first)",
        "mimeType" => "application/json"
      },
      %{
        "uriTemplate" => "#{@uri_scheme}://approvals/{company}",
        "name" => "pending-approvals",
        "description" => "Tasks awaiting Director approval (GEP-19)",
        "mimeType" => "application/json"
      },
      %{
        "uriTemplate" => "#{@uri_scheme}://proposals/{company}",
        "name" => "proposals",
        "description" => "GEP-28 proposals for a company",
        "mimeType" => "application/json"
      }
    ]
  end

  @doc """
  Read a resource URI and return MCP-spec `resources/read` result
  shape: `{contents: [{uri, mimeType, text}]}`.

  Returns `{:ok, result_map}` on success, `{:error, code, message,
  data}` on failure — the plug maps these to JSON-RPC errors. Code
  `-32002` for not-found, `-32603` for internal / parse errors.
  """
  @spec read(String.t(), map()) ::
          {:ok, map()}
          | {:error, integer(), String.t(), map()}
  def read(uri, context) when is_binary(uri) do
    with {:ok, parsed} <- parse_uri(uri),
         :ok <- ensure_exists(parsed, context) do
      do_read(parsed, uri, context)
    else
      {:error, reason} ->
        {:error, -32_002, "Resource not found", %{"uri" => uri, "reason" => reason}}
    end
  end

  def read(_uri, _context),
    do: {:error, -32_002, "Resource not found", %{"reason" => "uri must be a string"}}

  # ---------------------------------------------------------------------------
  # URI parsing
  # ---------------------------------------------------------------------------

  # Accept only the shapes we understand. Slug-gate each segment to
  # close the same path-traversal surface MCP tools already defend.
  defp parse_uri("glorbo://audit/" <> company) do
    with {:ok, co} <- split_one_segment(company),
         true <- Slug.valid?(co) do
      {:ok, {:audit, co}}
    else
      _ -> {:error, :invalid_company_slug}
    end
  end

  defp parse_uri("glorbo://approvals/" <> company) do
    with {:ok, co} <- split_one_segment(company),
         true <- Slug.valid?(co) do
      {:ok, {:approvals, co}}
    else
      _ -> {:error, :invalid_company_slug}
    end
  end

  defp parse_uri("glorbo://proposals/" <> company) do
    with {:ok, co} <- split_one_segment(company),
         true <- Slug.valid?(co) do
      {:ok, {:proposals, co}}
    else
      _ -> {:error, :invalid_company_slug}
    end
  end

  defp parse_uri("glorbo://chat/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [co, ch] ->
        if Slug.valid?(co) and Slug.valid?(ch),
          do: {:ok, {:chat, co, ch}},
          else: {:error, :invalid_slug}

      _ ->
        {:error, :bad_chat_uri}
    end
  end

  defp parse_uri(_), do: {:error, :unknown_scheme_or_shape}

  # A company URI has exactly one segment after the scheme — no
  # nested paths allowed, and no trailing slash. Keeping URI
  # identity strict matters for resources/subscribe (wave d.2) so
  # the canonical form is the only key we'll need to match.
  defp split_one_segment(value) do
    case String.split(value, "/", parts: 2) do
      [segment] -> {:ok, segment}
      _ -> {:error, :extra_segments}
    end
  end

  # ---------------------------------------------------------------------------
  # Existence checks — keep resources/read consistent with resources/list
  # (unknown company/channel → -32002, not an empty JSON payload)
  # ---------------------------------------------------------------------------

  defp ensure_exists({_kind, company}, context) do
    company_exists?(company, context)
  end

  defp ensure_exists({:chat, company, _channel}, context) do
    # Channel existence is already enforced by GetChannel.call →
    # {:error, {:channel_not_found, _}}; we only need to gate the
    # company here so the error message is consistent.
    company_exists?(company, context)
  end

  defp company_exists?(company, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    path = Path.join([base, "companies", company])
    if File.dir?(path), do: :ok, else: {:error, :unknown_company}
  end

  # ---------------------------------------------------------------------------
  # Dispatch per resource kind — reuse the existing read tools
  # ---------------------------------------------------------------------------

  defp do_read({:audit, company}, uri, context) do
    # Bounded audit snapshot: ~100 rows from the current month.
    # Clients wanting more can call glorbo.query_audit with filters.
    args = %{"company" => company, "limit" => 100}

    case QueryAudit.call(args, context) do
      {:ok, %{"entries" => _} = payload} -> ok_json(uri, payload)
      {:error, err} -> read_err(uri, err)
    end
  end

  defp do_read({:approvals, company}, uri, context) do
    case ListPendingApprovals.call(%{"company" => company}, context) do
      {:ok, payload} -> ok_json(uri, payload)
      {:error, err} -> read_err(uri, err)
    end
  end

  defp do_read({:proposals, company}, uri, context) do
    case ListProposals.call(%{"company" => company}, context) do
      {:ok, payload} -> ok_json(uri, payload)
      {:error, err} -> read_err(uri, err)
    end
  end

  defp do_read({:chat, company, channel}, uri, context) do
    args = %{"company" => company, "channel" => channel}

    case GetChannel.call(args, context) do
      {:ok, payload} ->
        ok_json(uri, payload)

      {:error, {:channel_not_found, _}} ->
        {:error, -32_002, "Resource not found", %{"uri" => uri}}

      {:error, err} ->
        read_err(uri, err)
    end
  end

  # ---------------------------------------------------------------------------
  # Response shape helpers
  # ---------------------------------------------------------------------------

  defp ok_json(uri, payload) do
    {:ok,
     %{
       "contents" => [
         %{
           "uri" => uri,
           "mimeType" => "application/json",
           "text" => Jason.encode!(payload)
         }
       ]
     }}
  end

  defp read_err(uri, reason) do
    {:error, -32_603, "Resource read failed", %{"uri" => uri, "reason" => inspect(reason)}}
  end

  # ---------------------------------------------------------------------------
  # Enumeration
  # ---------------------------------------------------------------------------

  defp resources_for_company(base, slug) do
    co_path = Path.join([base, "companies", slug])

    base_entries = [
      resource("audit", slug, "#{@uri_scheme}://audit/#{slug}",
        description: "Audit log for company #{slug}"
      ),
      resource("approvals", slug, "#{@uri_scheme}://approvals/#{slug}",
        description: "Pending director approvals for #{slug}"
      ),
      resource("proposals", slug, "#{@uri_scheme}://proposals/#{slug}",
        description: "Proposals for #{slug}"
      )
    ]

    channel_entries =
      case File.ls(Path.join(co_path, "channels")) do
        {:ok, files} ->
          files
          |> Enum.sort()
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.basename(&1, ".md"))
          |> Enum.filter(&Slug.valid?/1)
          |> Enum.map(fn ch ->
            resource("chat", "#{slug}/#{ch}", "#{@uri_scheme}://chat/#{slug}/#{ch}",
              description: "Messages on #{slug}/##{ch}"
            )
          end)

        _ ->
          []
      end

    base_entries ++ channel_entries
  end

  defp resource(name, suffix, uri, opts) do
    %{
      "uri" => uri,
      "name" => "#{name}:#{suffix}",
      "description" => Keyword.fetch!(opts, :description),
      "mimeType" => "application/json"
    }
  end
end
