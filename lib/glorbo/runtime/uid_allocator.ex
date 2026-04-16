defmodule Glorbo.Runtime.UidAllocator do
  @moduledoc """
  Per-company UID block allocator with subordinate-UID base detection.

  Reads `/etc/subuid` to find the Director's subordinate UID range, then
  assigns 100-UID blocks per company (D-02 reinterpreted: uid_base =
  subuid_base + 100 * company_ordinal).

  Allocations are persisted to a JSON sidecar at
  `~/.glorbo/runtime/.companies-uid.json` with mode 0600 (T-03-02).

  Agent removal soft-retires the UID (tombstoned, not recycled) so audit
  log foreign keys stay valid (D-04).

  All IO paths are injectable via opts for testability.
  """

  @type allocation :: %{
          company: String.t(),
          ordinal: non_neg_integer(),
          uid_base: pos_integer(),
          agents: %{String.t() => pos_integer()},
          tombstoned: [String.t()]
        }

  @doc """
  Read the subordinate UID base for a user from /etc/subuid.

  Returns `{:ok, base}` or `{:error, :no_subuid_entry}`.
  """
  @spec subuid_base(keyword()) :: {:ok, pos_integer()} | {:error, :no_subuid_entry}
  def subuid_base(opts \\ []) do
    path = Keyword.get(opts, :subuid_path, "/etc/subuid")
    user = Keyword.get(opts, :user, System.get_env("USER", ""))

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> find_user_subuid(user)

      {:error, _} ->
        {:error, :no_subuid_entry}
    end
  end

  defp find_user_subuid(lines, user) do
    Enum.find_value(lines, {:error, :no_subuid_entry}, fn line ->
      case String.split(line, ":") do
        [^user, base_str | _] -> {:ok, String.to_integer(base_str)}
        _ -> nil
      end
    end)
  end

  @doc """
  Read current allocations from the sidecar JSON file.

  Returns `%{}` if the file doesn't exist yet.
  """
  @spec current_allocations(keyword()) :: %{String.t() => allocation()}
  def current_allocations(opts \\ []) do
    sidecar_path = Keyword.get(opts, :sidecar_path, default_sidecar_path())

    case File.read(sidecar_path) do
      {:ok, content} ->
        content
        |> Jason.decode!()
        |> Map.new(fn {company, data} ->
          {company, decode_allocation(data)}
        end)

      {:error, :enoent} ->
        %{}
    end
  end

  @doc """
  Allocate (or update) a UID block for a company.

  On first call for a company: assigns the next ordinal (0-based), computes
  uid_base = subuid_base + 100 * ordinal, assigns sequential UIDs to agents.

  On subsequent calls: adds new agents at the next free UID, tombstones
  removed agents (UIDs are NOT recycled per D-04).
  """
  @spec allocate(String.t(), [String.t()], keyword()) ::
          {:ok, allocation()} | {:error, term()}
  def allocate(company, agents, opts \\ []) do
    with {:ok, base} <- subuid_base(opts) do
      sidecar_path = Keyword.get(opts, :sidecar_path, default_sidecar_path())
      allocs = current_allocations(opts)

      alloc =
        case Map.get(allocs, company) do
          nil ->
            ordinal = map_size(allocs)
            uid_base = base + 100 * ordinal
            agent_map = assign_agents(agents, uid_base, %{}, [])

            %{
              company: company,
              ordinal: ordinal,
              uid_base: uid_base,
              agents: agent_map,
              tombstoned: []
            }

          existing ->
            update_allocation(existing, agents)
        end

      updated_allocs = Map.put(allocs, company, alloc)
      write_sidecar(sidecar_path, updated_allocs)

      {:ok, alloc}
    end
  end

  # Assign UIDs to agents sequentially from uid_base, skipping already-assigned
  # and tombstoned UIDs.
  defp assign_agents(agents, uid_base, existing_agents, _tombstoned) do
    # Find the next free UID offset
    used_offsets =
      existing_agents
      |> Map.values()
      |> Enum.map(fn uid -> uid - uid_base end)
      |> MapSet.new()

    {agent_map, _} =
      Enum.reduce(agents, {existing_agents, 0}, fn agent, {acc, next_offset} ->
        if Map.has_key?(acc, agent) do
          {acc, next_offset}
        else
          offset = find_next_free(next_offset, used_offsets)
          {Map.put(acc, agent, uid_base + offset), offset + 1}
        end
      end)

    agent_map
  end

  defp find_next_free(offset, used) do
    if MapSet.member?(used, offset), do: find_next_free(offset + 1, used), else: offset
  end

  # Update an existing allocation: add new agents, tombstone removed ones.
  defp update_allocation(existing, agents) do
    current_agents = Map.keys(existing.agents)
    new_agents = agents -- current_agents
    removed_agents = current_agents -- agents

    # Add new agents at next free UIDs
    updated_agents =
      if new_agents == [] do
        existing.agents
      else
        assign_agents(
          new_agents,
          existing.uid_base,
          existing.agents,
          existing.tombstoned
        )
      end

    # Remove removed agents from active map
    updated_agents = Map.drop(updated_agents, removed_agents)

    # Add removed agents to tombstoned (no recycling — D-04)
    updated_tombstoned =
      (existing.tombstoned ++ removed_agents)
      |> Enum.uniq()

    %{existing | agents: updated_agents, tombstoned: updated_tombstoned}
  end

  # Write the sidecar JSON atomically with mode 0600.
  defp write_sidecar(path, allocs) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    encoded =
      allocs
      |> Map.new(fn {company, alloc} -> {company, encode_allocation(alloc)} end)
      |> Jason.encode!(pretty: true)

    tmp_path = path <> ".tmp"
    File.write!(tmp_path, encoded)
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, path)
  end

  defp encode_allocation(alloc) do
    %{
      "company" => alloc.company,
      "ordinal" => alloc.ordinal,
      "uid_base" => alloc.uid_base,
      "agents" => alloc.agents,
      "tombstoned" => alloc.tombstoned
    }
  end

  defp decode_allocation(data) do
    %{
      company: data["company"],
      ordinal: data["ordinal"],
      uid_base: data["uid_base"],
      agents: data["agents"],
      tombstoned: data["tombstoned"] || []
    }
  end

  defp default_sidecar_path do
    Path.expand("~/.glorbo/runtime/.companies-uid.json")
  end
end
