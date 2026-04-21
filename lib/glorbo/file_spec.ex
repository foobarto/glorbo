defmodule Glorbo.FileSpec do
  @moduledoc """
  Registry of on-disk file specs (GEP-25).

  Every markdown-with-frontmatter or JSON(L) file Glorbo reads or
  writes under `~/.glorbo/` is catalogued here. Each per-kind module
  implements this behaviour and declares:

    * the `kind: <name>/<version>` discriminator (k8s-inspired)
    * the frontmatter schema (required/optional keys, enums, patterns,
      caps)
    * canonical key ordering for the formatter
    * path classification rule (fallback when `kind:` is absent — the
      atomic cut removes most fallback cases)

  `classify/1` returns the spec module for a path by reading
  `kind:` from frontmatter first, falling back to
  `path_match?/1` only when the file is unparseable or brand-new.
  Mismatch between the `kind:` value and the path is caller-side
  discrepancy the validator flags as an error (D8).

  Current status: **scaffolding only** (R26.1). Validator +
  formatter + CLI verbs land in follow-up commits. No existing
  writer reads from this module yet.
  """

  @type finding :: %{
          required(:severity) => :error | :warning | :info,
          required(:file) => Path.t(),
          required(:code) => atom(),
          required(:message) => binary(),
          optional(:line) => non_neg_integer()
        }

  @type schema :: %{
          required(:required) => [atom()],
          required(:optional) => [atom()],
          optional(:enums) => %{optional(atom()) => [binary()]},
          optional(:patterns) => %{optional(atom()) => Regex.t()},
          optional(:caps) => %{optional(atom()) => non_neg_integer()}
        }

  @doc "The `kind:` value this spec describes, e.g. `\"task/v1\"`."
  @callback kind() :: binary()

  @doc "Path-based fallback classifier. Returns true if `path` looks like this kind."
  @callback path_match?(path :: Path.t()) :: boolean()

  @doc "Frontmatter schema — required/optional keys, enums, patterns, caps."
  @callback frontmatter_schema() :: schema()

  @doc """
  Canonical order for frontmatter keys on write. Keys not in this
  list fall at the end, sorted alphabetically.
  """
  @callback canonical_key_order() :: [atom()]

  @doc "Human-readable spec summary — fed into `docs/file-formats/`."
  @callback docs() :: %{
              required(:title) => binary(),
              required(:summary) => binary(),
              optional(:examples) => [binary()]
            }

  # Spec registry — ordered, first-match wins on path classification.
  # Ordering matters only where regexes overlap; e.g. SkillMd
  # matches `/skills/<n>.md` distinctly from any other kind so its
  # position is flexible. Memory/index + sentinel specs have mutually
  # disjoint regexes.
  @specs [
    Glorbo.FileSpec.CompanyMd,
    Glorbo.FileSpec.AgentMd,
    Glorbo.FileSpec.ProjectMd,
    Glorbo.FileSpec.TaskMd,
    Glorbo.FileSpec.SkillMd,
    Glorbo.FileSpec.HeartbeatMd,
    Glorbo.FileSpec.SoulMd,
    Glorbo.FileSpec.MemoryIndexMd,
    Glorbo.FileSpec.MemoryEntryMd,
    Glorbo.FileSpec.SentinelApprovalMd,
    Glorbo.FileSpec.SentinelStuckMd,
    Glorbo.FileSpec.SentinelResolutionMd,
    Glorbo.FileSpec.BraindumpMd,
    Glorbo.FileSpec.ChannelLogMd,
    Glorbo.FileSpec.AuditMonthJsonl,
    Glorbo.FileSpec.InboxArchiveJson,
    Glorbo.FileSpec.EmergencyStopMd,
    Glorbo.FileSpec.InboxMessageMd
  ]

  @doc """
  All registered spec modules, in classification order. Used by the
  docs generator, the validator, and the formatter.
  """
  @spec specs() :: [module()]
  def specs, do: @specs

  @doc """
  Classify a path to its spec module using path-matching only. This
  is the fallback path for files that haven't been parsed yet; the
  validator also reads `kind:` from parsed frontmatter and
  cross-checks against `classify_by_path/1`.

  Returns `{:ok, module()}` or `{:error, :unknown}`.
  """
  @spec classify_by_path(Path.t()) :: {:ok, module()} | {:error, :unknown}
  def classify_by_path(path) when is_binary(path) do
    case Enum.find(@specs, & &1.path_match?(path)) do
      nil -> {:error, :unknown}
      mod -> {:ok, mod}
    end
  end

  @doc """
  Classify a parsed frontmatter map to its spec module via the
  `kind:` field. Paired with `classify_by_path/1` at the validator
  layer so mismatch can be flagged.
  """
  @spec classify_by_kind(map()) :: {:ok, module()} | {:error, :missing_kind | :unknown_kind}
  def classify_by_kind(%{} = fm) do
    case Map.get(fm, "kind") || Map.get(fm, :kind) do
      nil ->
        {:error, :missing_kind}

      value when is_binary(value) ->
        case Enum.find(@specs, &(&1.kind() == value)) do
          nil -> {:error, :unknown_kind}
          mod -> {:ok, mod}
        end
    end
  end
end
