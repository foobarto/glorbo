defmodule Glorbo.Actions.Support do
  @moduledoc """
  Shared utilities for `Glorbo.Actions.*` modules (GEP-36).

  The Actions carve-out accumulated eight modules over Round M
  (Tasks, Companies, Projects, Audit, Channels, Inbox, Attachments,
  Agents) that each duplicated the same small helpers:

    * slug validation against `~r/\\A[a-z0-9][a-z0-9-]*\\z/`
    * `AuditLog` routing that handles the bare-module /
      via-tuple / explicit-pid / `:noproc` cases
    * the `~/.glorbo/` filesystem root lookup
    * `put_detail/3` for string-keyed audit-entry details

  Lifting them here keeps the per-action modules focused on
  validation + mutation, and lets future Action additions inherit
  the conventions without re-deriving them.

  This module is **only for Action modules** — callers outside the
  carve-out should talk to the domain directly, not to the audit
  routing helper.
  """

  alias Glorbo.Company.AuditLog

  @slug_re ~r/\A[a-z0-9][a-z0-9-]*\z/

  @doc "The canonical slug regex used across all Action modules."
  @spec slug_re() :: Regex.t()
  def slug_re, do: @slug_re

  @doc "True iff `s` is a binary matching `slug_re/0`."
  @spec valid_slug?(term()) :: boolean()
  def valid_slug?(s) when is_binary(s), do: Regex.match?(@slug_re, s)
  def valid_slug?(_), do: false

  @doc """
  Validate a slug value. Returns `:ok` or
  `{:error, {:invalid_slug, kind, slug}}`.

  `kind` is an atom like `:company`, `:project`, `:channel`, `:agent`,
  surfaced in the error tuple so callers can distinguish which
  slug on a multi-slug call failed.
  """
  @spec validate_slug(String.t(), atom()) ::
          :ok | {:error, {:invalid_slug, atom(), term()}}
  def validate_slug(slug, kind) when is_binary(slug) and is_atom(kind) do
    if valid_slug?(slug), do: :ok, else: {:error, {:invalid_slug, kind, slug}}
  end

  def validate_slug(slug, kind) when is_atom(kind) do
    {:error, {:invalid_slug, kind, slug}}
  end

  @doc "Default filesystem root — `~/.glorbo/` or the GLORBO_HOME override."
  @spec default_base() :: String.t()
  def default_base, do: Glorbo.Filesystem.Hierarchy.default_root()

  @doc """
  Conditionally insert a string-keyed detail into an audit entry
  map. Drops nil and empty-string values (so optional fields that
  weren't supplied don't clutter the audit record) and stringifies
  everything else.
  """
  @spec put_detail(map(), String.t(), term()) :: map()
  def put_detail(map, _key, nil), do: map
  def put_detail(map, _key, ""), do: map
  def put_detail(map, key, value), do: Map.put(map, key, to_string(value))

  @doc """
  Append an audit entry, routing between:

    * the bare `AuditLog` atom (production default) — goes via
      `AuditLog.append_for/2` (per-company-named Registry
      lookup, with `:noproc` swallowed so the already-landed
      filesystem write isn't reverted).
    * an explicit atom or pid (test sinks like `FakeAudit`) —
      goes via `AuditLog.append/2` on that target.
    * anything else (custom via-tuples, etc.) — also routed
      through `AuditLog.append/2`.
  """
  @spec append_audit(atom() | pid() | term(), String.t(), map()) :: :ok
  def append_audit(AuditLog, company, entry), do: safe_append_for(company, entry)

  def append_audit(target, _company, entry) when is_atom(target) or is_pid(target),
    do: AuditLog.append(target, entry)

  def append_audit(other, _company, entry), do: AuditLog.append(other, entry)

  defp safe_append_for(company, entry) do
    AuditLog.append_for(company, entry)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {{:noproc, _}, _} -> :ok
  end
end
