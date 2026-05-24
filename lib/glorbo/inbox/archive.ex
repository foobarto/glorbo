defmodule Glorbo.Inbox.Archive do
  @moduledoc """
  Persistent "I handled this" set for InboxLive's Archive tab
  (paperclip-ux-gaps §3 follow-up).

  Stores a list of opaque string keys in
  `<base>/companies/<co>/audit/_inbox_archive.json`. The Archive
  flow is purely director-facing — agents don't read or write this
  file, so keeping it in `audit/` alongside the audit logs (without
  being one) is the simplest home. It is NOT part of the audit
  contract (non-append-only), it is *local UI state* scoped to one
  company directory.

  Corruption is non-fatal: a malformed file yields an empty set.
  Rebuild by deleting the file — the worst case is losing the
  director's "already handled" marks.
  """

  @type key :: String.t()

  @filename "_inbox_archive.json"

  # Gemini round-4 finding (PR #36, LOW defense-in-depth): all
  # live callers (InboxLive) already gate on `Slug.valid?` —
  # adding the guard here too so a future caller that forgets
  # the gate can't `..` into `Path.join` via `company: "../../etc"`.
  # Mirrors the round-3 audit/query hardening.
  @spec list(Path.t(), String.t()) :: MapSet.t(key())
  def list(base, company) when is_binary(company) do
    if Glorbo.Slug.valid?(company) do
      case File.read(path(base, company)) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"keys" => keys}} when is_list(keys) -> MapSet.new(keys, &to_string/1)
            _ -> MapSet.new()
          end

        _ ->
          MapSet.new()
      end
    else
      MapSet.new()
    end
  end

  @spec add(Path.t(), String.t(), key()) :: :ok | {:error, :invalid_company}
  def add(base, company, key) when is_binary(company) and is_binary(key) do
    if Glorbo.Slug.valid?(company) do
      set = list(base, company) |> MapSet.put(key)
      write(base, company, set)
    else
      {:error, :invalid_company}
    end
  end

  @spec remove(Path.t(), String.t(), key()) :: :ok | {:error, :invalid_company}
  def remove(base, company, key) when is_binary(company) and is_binary(key) do
    if Glorbo.Slug.valid?(company) do
      set = list(base, company) |> MapSet.delete(key)
      write(base, company, set)
    else
      {:error, :invalid_company}
    end
  end

  @spec member?(MapSet.t(key()), key()) :: boolean()
  def member?(set, key) when is_binary(key), do: MapSet.member?(set, key)

  defp write(base, company, set) do
    path = path(base, company)
    File.mkdir_p!(Path.dirname(path))

    record = %{
      "kind" => "inbox-archive/v1",
      "keys" => MapSet.to_list(set),
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write!(path, Jason.encode!(record))
    :ok
  end

  defp path(base, company),
    do: Path.join([base, "companies", company, "audit", @filename])
end
