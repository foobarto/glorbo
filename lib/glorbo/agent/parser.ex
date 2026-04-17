defmodule Glorbo.Agent.Parser do
  @moduledoc """
  Parse + validate `agent.md` frontmatter into a `Glorbo.Agent.Spec` struct
  (D-02, D-43, LLM-03, LLM-04).

  ## Behaviour

    * Reads the file via `File.read/1`, then parses frontmatter through
      `Glorbo.Filesystem.Frontmatter.parse/1` (Phase 2 safe-loader,
      `yamerl`-backed, 10 MB cap).
    * Validates every field against fixed allowlists (provider, network,
      permission tuples, skill names, slug pattern).
    * **Never** calls `String.to_atom/1` on user input (T-03-15 mitigation).
    * Rejects `agents:create:*` permissions at parse time (AGT-05 P15
      defence-in-depth).

  ## Allowlists + invariants

    * `@allowed_providers` — `["claude-code", "gemini-cli", "codex"]` (D-02).
    * `@network_map` — `"none" → :none | "api-only" → :api_only | "open" → :open`.
    * `@skill_name_regex` / `@slug_regex` — `~r/\A[a-z][a-z0-9_-]{0,63}\z/`
      (T-03-19 path-traversal block; bounds slug to kebab-case ASCII).
    * `model:` is REQUIRED for all three providers (LLM-04 single-model
      invariant). Missing → `{:error, :missing_model}`; list value →
      `{:error, :multiple_models_not_supported}`.
    * `permissions:` defaults to `[]` when absent (P7 — agent with no granted
      permissions is valid; it just can't route anything).
    * `network:` defaults to `:none` (P9 — secure-by-default).
    * `timeout_seconds:` defaults to 300 (D-06).
    * `budget_usd_cents_month:` defaults to `nil` (P11 — no cap == no
      hard-stop, matches BudgetTracker semantics).

  Threat model mitigations applied here:

    * T-03-15 (Tampering): provider/network pattern-matched against fixed
      lists; permission tuples via `Glorbo.Security.ACLMapper.parse_permission/1`
      (which has its own whitelist); slug regex; `agents_create_forbidden`
      check (P15).
    * T-03-19 (Info disclosure): skill-name regex blocks `../` traversal;
      the filesystem-side check is in `Glorbo.Skills.Resolver`.
  """
  alias Glorbo.Agent.Spec
  alias Glorbo.Filesystem.Frontmatter
  alias Glorbo.Security.ACLMapper

  @allowed_providers ["claude-code", "gemini-cli", "codex"]
  @network_map %{"none" => :none, "api-only" => :api_only, "open" => :open}
  @default_timeout_seconds 300
  @slug_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @skill_name_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @type parse_error ::
          {:invalid_provider, String.t()}
          | :missing_model
          | :multiple_models_not_supported
          | {:invalid_permission, String.t()}
          | {:invalid_network, String.t()}
          | {:invalid_skill_name, String.t()}
          | {:invalid_slug, String.t()}
          | :agents_create_forbidden
          | {:frontmatter, term()}
          | {:read_error, term()}

  @doc """
  Read an `agent.md` file from disk and return a validated
  `Glorbo.Agent.Spec` struct.

  Returns `{:ok, %Spec{}}` on success or `{:error, reason}` on any
  validation or IO failure. Never raises on user-controlled input.
  """
  @spec parse_file(Path.t()) :: {:ok, Spec.t()} | {:error, parse_error()}
  def parse_file(path) when is_binary(path) do
    with {:ok, content} <- read_file(path),
         {:ok, meta, _body} <- parse_frontmatter(content),
         {:ok, slug} <- derive_slug(path),
         {:ok, company} <- derive_company(path) do
      validate(meta, slug, company, path)
    end
  end

  @doc """
  Lower-level entry point for pre-read content: validate a parsed
  frontmatter map (as returned by `Glorbo.Filesystem.Frontmatter.parse/1`)
  into a `Spec`.
  """
  @spec parse_frontmatter(binary()) :: {:ok, map(), binary()} | {:error, parse_error()}
  def parse_frontmatter(content) when is_binary(content) do
    case Frontmatter.parse(content) do
      {:ok, meta, body} -> {:ok, meta, body}
      {:error, reason} -> {:error, {:frontmatter, reason}}
    end
  end

  @doc """
  Apply every field-level validation to a parsed frontmatter map and
  produce a `Spec`. Exposed for tests that want to exercise the validator
  without touching the filesystem.
  """
  @spec validate(map(), String.t(), String.t(), Path.t()) ::
          {:ok, Spec.t()} | {:error, parse_error()}
  def validate(meta, slug, company, file_path) when is_map(meta) do
    with :ok <- validate_slug(slug),
         {:ok, provider} <- validate_provider(meta["provider"]),
         {:ok, model} <- validate_model(meta["model"]),
         {:ok, permissions} <- validate_permissions(meta["permissions"] || []),
         :ok <- reject_agents_create(permissions),
         {:ok, network} <- validate_network(meta["network"]),
         {:ok, skills} <- validate_skills(meta["skills"]),
         {:ok, heartbeat} <- validate_heartbeat(meta["heartbeat"]),
         {:ok, budget} <- validate_budget(meta["budget_usd_cents_month"]),
         {:ok, timeout} <- validate_timeout(meta["timeout_seconds"]) do
      {:ok,
       %Spec{
         slug: slug,
         company: company,
         role: to_string(meta["role"] || ""),
         provider: provider,
         model: model,
         permissions: permissions,
         heartbeat: heartbeat,
         network: network,
         skills: skills,
         budget_usd_cents_month: budget,
         timeout_seconds: timeout,
         allow_untracked_budget: parse_untracked(meta["allow_untracked_budget"]),
         file_path: file_path
       }}
    end
  end

  defp parse_untracked(true), do: true
  defp parse_untracked(_), do: false

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  # agent.md path shape: ".../companies/<co>/agents/<slug>/agent.md"
  defp derive_slug(path) do
    parts = Path.split(path)

    case Enum.reverse(parts) do
      ["agent.md", slug | _] ->
        if Regex.match?(@slug_regex, slug) do
          {:ok, slug}
        else
          {:error, {:invalid_slug, slug}}
        end

      _ ->
        {:error, {:invalid_slug, path}}
    end
  end

  defp validate_slug(slug) do
    if Regex.match?(@slug_regex, slug) do
      :ok
    else
      {:error, {:invalid_slug, slug}}
    end
  end

  # Extract company slug from ".../companies/<co>/agents/<slug>/agent.md".
  # If the path doesn't fit that shape we default to "" — the company is
  # usually provided explicitly by the caller (AgentSupervisor will override
  # it). Tests that rely on path-derived company use the canonical layout.
  defp derive_company(path) do
    parts = path |> Path.split() |> Enum.reverse()

    case parts do
      ["agent.md", _slug, "agents", company | _] -> {:ok, company}
      _ -> {:ok, ""}
    end
  end

  defp validate_provider(nil), do: {:error, {:invalid_provider, ""}}

  defp validate_provider(provider) when is_binary(provider) do
    # Pattern-match against fixed allowlist — no String.to_atom on user input
    # (T-03-15). Any string outside @allowed_providers is rejected verbatim.
    if provider in @allowed_providers do
      {:ok, provider}
    else
      {:error, {:invalid_provider, provider}}
    end
  end

  defp validate_provider(other), do: {:error, {:invalid_provider, inspect(other)}}

  # LLM-04: model MUST be a single string. Missing → missing_model; list →
  # multiple_models_not_supported.
  defp validate_model(nil), do: {:error, :missing_model}
  defp validate_model(""), do: {:error, :missing_model}
  defp validate_model(model) when is_binary(model), do: {:ok, model}
  defp validate_model(list) when is_list(list), do: {:error, :multiple_models_not_supported}
  defp validate_model(_), do: {:error, :missing_model}

  # Validate permissions list. Each entry must be a binary "resource:action:scope"
  # parseable by ACLMapper. Non-binary entries (e.g. yaml nested maps) are rejected.
  defp validate_permissions(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case validate_one_permission(entry) do
        {:ok, perm} -> {:cont, {:ok, [perm | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp validate_permissions(_), do: {:ok, []}

  defp validate_one_permission(entry) when is_binary(entry) do
    case ACLMapper.parse_permission(entry) do
      {:ok, perm} -> {:ok, perm}
      {:error, _} -> {:error, {:invalid_permission, entry}}
    end
  end

  defp validate_one_permission(entry),
    do: {:error, {:invalid_permission, inspect(entry)}}

  # AGT-05 P15 — no agent may DECLARE agents:create in v0.0.1. Router already
  # blocks routing of agent-creation payloads (Plan 03-02); this is a parse-time
  # defence-in-depth so the refusal is visible at the agent definition layer.
  defp reject_agents_create(permissions) do
    if Enum.any?(permissions, fn {r, a, _} -> r == "agents" and a == "create" end) do
      {:error, :agents_create_forbidden}
    else
      :ok
    end
  end

  # Network policy. Nil defaults to :none (secure-by-default per V14).
  defp validate_network(nil), do: {:ok, :none}
  defp validate_network(""), do: {:ok, :none}

  defp validate_network(raw) when is_binary(raw) do
    case Map.fetch(@network_map, raw) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_network, raw}}
    end
  end

  defp validate_network(other), do: {:error, {:invalid_network, inspect(other)}}

  # Skills list normalisation: nil → []; scalar "foo" → ["foo"]; list as-is.
  # Each entry must pass the skill-name regex (T-03-19 path-traversal gate).
  defp validate_skills(nil), do: {:ok, []}
  defp validate_skills(""), do: {:ok, []}

  defp validate_skills(name) when is_binary(name) do
    validate_skills([name])
  end

  defp validate_skills(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case validate_one_skill(entry) do
        {:ok, name} -> {:cont, {:ok, [name | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp validate_skills(_), do: {:ok, []}

  defp validate_one_skill(name) when is_binary(name) do
    if Regex.match?(@skill_name_regex, name) do
      {:ok, name}
    else
      {:error, {:invalid_skill_name, name}}
    end
  end

  defp validate_one_skill(other),
    do: {:error, {:invalid_skill_name, inspect(other)}}

  # Heartbeat: cron string or nil. Validation of cron SHAPE is the Scheduler's
  # job at register-time; here we only check it's a binary or absent.
  defp validate_heartbeat(nil), do: {:ok, nil}
  defp validate_heartbeat(""), do: {:ok, nil}
  defp validate_heartbeat(cron) when is_binary(cron), do: {:ok, cron}
  defp validate_heartbeat(_), do: {:ok, nil}

  # Budget: positive integer cents or nil (no cap → no hard-stop).
  defp validate_budget(nil), do: {:ok, nil}
  defp validate_budget(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp validate_budget(_), do: {:ok, nil}

  # Timeout: positive integer seconds, default 300 (D-06).
  defp validate_timeout(nil), do: {:ok, @default_timeout_seconds}
  defp validate_timeout(v) when is_integer(v) and v > 0, do: {:ok, v}
  defp validate_timeout(_), do: {:ok, @default_timeout_seconds}
end
