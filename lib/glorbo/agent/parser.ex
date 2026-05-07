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

    * `@fallback_provider_kinds` — compile-time fallback when the live
      registry is unavailable.
    * `@network_map` — `"loopback" → :loopback | "proxy" → :proxy | "full" → :full`
      (GEP-23 D1 rename; pre-1.0 atomic cut away from the older
      `none | proxy | open` set).
    * `@skill_name_regex` / `@slug_regex` — `~r/\A[a-z][a-z0-9_-]{0,63}\z/`
      (T-03-19 path-traversal block; bounds slug to kebab-case ASCII).
    * `model:` is REQUIRED for all three providers (LLM-04 single-model
      invariant). Missing → `{:error, :missing_model}`; list value →
      `{:error, :multiple_models_not_supported}`.
    * `permissions:` defaults to `[]` when absent (P7 — agent with no granted
      permissions is valid; it just can't route anything).
    * `network:` defaults to `:loopback` (threatmodel M16 —
      secure-by-default). Templates that need egress set
      `network: proxy` explicitly. We still don't silently opt agents
      into egress when the field is missing, even though GEP-31 now
      enforces proxy-only Linux networking, because `:loopback`
      remains the honest least-privilege default.
    * `timeout_seconds:` defaults to 300 (D-06).
    * `http_timeout_s:` defaults to 120; `http_max_retries:` to 3;
      `web_fetch_timeout_s:` to 30; `max_tool_calls_per_turn:` to 50
      (GEP-32 phase 2b runtime defaults).
    * `budget.monthly_usd:` defaults to `nil` (P11 — no cap == no
      hard-stop, matches BudgetTracker semantics). Legacy
      `budget_usd_cents_month:` is still accepted for compatibility.

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

  # Pre-GEP-8 hardcoded shortlist. Kept as a fallback when the live
  # registry isn't running (unit-test contexts) or hasn't loaded any
  # provider TOMLs yet. At runtime the accepted provider set is
  # whatever `Glorbo.CLI.Registry.list/0` reports — opencode, hermes,
  # pi, etc., all qualify, matching what the director sees on
  # `/providers`.
  @fallback_provider_kinds %{
    "claude-code" => :cli,
    "gemini-cli" => :cli,
    "codex" => :cli,
    "openai" => :native,
    "openrouter" => :native
  }
  @fallback_providers Map.keys(@fallback_provider_kinds)
  # GEP-23 D1 rename: `none → loopback` and `open → full`. The
  # atoms inside Glorbo are the new names; the string keys accept
  # ONLY the new names too (pre-1.0 atomic cut — no back-compat
  # reader).
  @network_map %{"loopback" => :loopback, "proxy" => :proxy, "full" => :full}
  @default_timeout_seconds 300
  @default_http_timeout_s 120
  @default_http_max_retries 3
  @default_web_fetch_timeout_s 30
  @default_max_tool_calls_per_turn 50
  @slug_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @skill_name_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @type parse_error ::
          {:invalid_provider, String.t()}
          | :missing_model
          | :multiple_models_not_supported
          | {:invalid_permission, String.t()}
          | {:invalid_network, String.t()}
          | {:native_provider_requires_network, String.t()}
          | {:invalid_autonomy, String.t()}
          | {:invalid_skill_name, String.t()}
          | {:invalid_slug, String.t()}
          | {:invalid_models_aliases, term()}
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
    with :ok <- require_kind(meta),
         :ok <- validate_slug(slug),
         {:ok, provider} <- validate_provider(meta["provider"]),
         {:ok, model} <- validate_model(meta["model"]),
         {:ok, models} <- validate_models_aliases(meta["models"]),
         {:ok, permissions} <- validate_permissions(meta["permissions"] || []),
         :ok <- reject_agents_create(permissions),
         {:ok, network} <- validate_network(meta["network"], provider, provider_kind(provider)),
         {:ok, skills} <- validate_skills(meta["skills"]),
         {:ok, heartbeat} <- validate_heartbeat(meta["heartbeat"]),
         {:ok, budget} <- validate_budget(meta["budget"], meta["budget_usd_cents_month"]),
         {:ok, timeout} <- validate_timeout(meta["timeout_seconds"]),
         {:ok, http_timeout_s} <- validate_http_timeout(meta["http_timeout_s"]),
         {:ok, http_max_retries} <- validate_http_max_retries(meta["http_max_retries"]),
         {:ok, web_fetch_timeout_s} <- validate_web_fetch_timeout(meta["web_fetch_timeout_s"]),
         {:ok, max_tool_calls_per_turn} <-
           validate_max_tool_calls_per_turn(meta["max_tool_calls_per_turn"]),
         {:ok, autonomy} <- validate_autonomy(meta["autonomy"]),
         {:ok, max_retries} <- validate_max_retries(meta["max_retries"]),
         {:ok, max_concurrency} <- validate_max_concurrency(meta["max_concurrency"]),
         {:ok, egress} <- validate_egress(meta["egress"]) do
      {:ok,
       %Spec{
         slug: slug,
         company: company,
         role: to_string(meta["role"] || ""),
         provider: provider,
         model: model,
         models: models,
         permissions: permissions,
         heartbeat: heartbeat,
         network: network,
         skills: skills,
         budget_usd_cents_month: budget,
         timeout_seconds: timeout,
         http_timeout_s: http_timeout_s,
         http_max_retries: http_max_retries,
         web_fetch_timeout_s: web_fetch_timeout_s,
         max_tool_calls_per_turn: max_tool_calls_per_turn,
         allow_untracked_budget: parse_untracked(meta["allow_untracked_budget"]),
         autonomy: autonomy,
         max_concurrency: max_concurrency,
         max_retries: max_retries,
         reports_to: parse_reports_to(meta["reports_to"]),
         icon: parse_icon(meta["icon"]),
         egress: egress,
         file_path: file_path
       }}
    end
  end

  # GEP-23 egress block (Phase 1, #287). Map with optional
  # `mode | allow | deny | smart_allow | smart_deny | smart_model`.
  # Missing block or empty map normalises to the Spec default
  # (mode: :allow, empty lists, empty smart strings). Invalid shape
  # rejects the whole agent file so a typo doesn't silently fall back
  # to a more permissive mode.
  defp validate_egress(nil), do: {:ok, default_egress()}
  defp validate_egress(map) when is_map(map) and map_size(map) == 0, do: {:ok, default_egress()}

  defp validate_egress(map) when is_map(map) do
    with {:ok, mode} <- parse_egress_mode(Map.get(map, "mode")),
         {:ok, allow} <- parse_host_list(Map.get(map, "allow", []), :allow),
         {:ok, deny} <- parse_host_list(Map.get(map, "deny", []), :deny) do
      {:ok,
       %{
         mode: mode,
         allow: allow,
         deny: deny,
         smart_allow: to_string(Map.get(map, "smart_allow", "")),
         smart_deny: to_string(Map.get(map, "smart_deny", "")),
         smart_model: parse_smart_model(Map.get(map, "smart_model"))
       }}
    end
  end

  defp validate_egress(other), do: {:error, {:invalid_egress, other}}

  defp default_egress do
    %{
      mode: :allow,
      allow: [],
      deny: [],
      smart_allow: "",
      smart_deny: "",
      smart_model: nil
    }
  end

  defp parse_egress_mode(nil), do: {:ok, :allow}
  defp parse_egress_mode("allow"), do: {:ok, :allow}
  defp parse_egress_mode("deny"), do: {:ok, :deny}
  defp parse_egress_mode("strict"), do: {:ok, :strict}
  defp parse_egress_mode("smart"), do: {:ok, :smart}
  defp parse_egress_mode(other), do: {:error, {:invalid_egress_mode, other}}

  defp parse_host_list(list, field) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      # Wave 26: refuse non-binary entries (maps/lists from YAML) up
      # front. The prior `to_string/1` raised Protocol.UndefinedError
      # on `egress.allow: [{nested: true}]`, crashing the parser
      # instead of returning a structured validation error.
      cond do
        not is_binary(entry) ->
          {:halt, {:error, {:invalid_egress_host, {field, entry}}}}

        entry == "" ->
          {:halt, {:error, {:invalid_egress_host, {field, :blank}}}}

        true ->
          {:cont, {:ok, [String.downcase(entry) | acc]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_host_list(other, field), do: {:error, {:invalid_egress_host, {field, other}}}

  defp parse_smart_model(nil), do: nil
  defp parse_smart_model(""), do: nil
  defp parse_smart_model(model) when is_binary(model), do: model
  defp parse_smart_model(_), do: nil

  # #236 — optional `models:` map of alias → concrete model name.
  #
  #   models:
  #     fast: claude-haiku-4-5
  #     reasoning: claude-opus-4-7
  #
  # All keys + values must be non-empty strings; keys must match the
  # skill/slug regex (kebab-case ASCII) so tasks can reference them
  # predictably. Missing / empty is an empty map — no aliases.
  defp validate_models_aliases(nil), do: {:ok, %{}}
  defp validate_models_aliases(map) when is_map(map) and map_size(map) == 0, do: {:ok, %{}}

  defp validate_models_aliases(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      # Wave 26: refuse non-binary keys/values up front. YAML can
      # nest maps/lists into the `models:` slot; `to_string/1` on
      # those raised Protocol.UndefinedError at boot/hot-reload.
      cond do
        not is_binary(k) ->
          {:halt, {:error, {:invalid_models_aliases, {:bad_alias_type, k}}}}

        not is_binary(v) ->
          {:halt, {:error, {:invalid_models_aliases, {:bad_model_type, v}}}}

        not Regex.match?(@skill_name_regex, k) ->
          {:halt, {:error, {:invalid_models_aliases, {:bad_alias, k}}}}

        v == "" ->
          {:halt, {:error, {:invalid_models_aliases, {:blank_model_for, k}}}}

        true ->
          {:cont, {:ok, Map.put(acc, k, v)}}
      end
    end)
  end

  defp validate_models_aliases(other),
    do: {:error, {:invalid_models_aliases, other}}

  defp parse_untracked(true), do: true
  defp parse_untracked(_), do: false

  # T1-F: autonomy tier mapping. Missing or unknown defaults to
  # `:supervised` — preserving pre-T1-F behaviour (no gate unless
  # declared at task level).
  defp validate_autonomy(nil), do: {:ok, :supervised}
  defp validate_autonomy(""), do: {:ok, :supervised}
  defp validate_autonomy("manual"), do: {:ok, :manual}
  defp validate_autonomy("supervised"), do: {:ok, :supervised}
  defp validate_autonomy("auto"), do: {:ok, :auto}
  defp validate_autonomy(raw), do: {:error, {:invalid_autonomy, inspect(raw)}}

  # Accepts a string (another agent's slug) or nil. No validation
  # against the existing agents list — the value is used at render-
  # time (org chart), where unknown slugs simply become leaf nodes.
  defp parse_reports_to(slug) when is_binary(slug) and byte_size(slug) > 0, do: slug
  defp parse_reports_to(_), do: nil

  # FontAwesome icon, allowlisted to `fa-[a-z0-9-]+` to prevent class
  # injection via frontmatter. Accepts either the raw modifier
  # (`rocket` → `fa-rocket`) or the already-prefixed form. Returns the
  # normalised `fa-<name>` string or nil.
  @fa_icon_regex ~r/\A[a-z][a-z0-9-]{0,63}\z/

  defp parse_icon(nil), do: nil
  defp parse_icon(""), do: nil

  defp parse_icon(raw) when is_binary(raw) do
    name = raw |> String.trim() |> String.downcase() |> String.replace_leading("fa-", "")

    if Regex.match?(@fa_icon_regex, name), do: "fa-#{name}", else: nil
  end

  defp parse_icon(_), do: nil

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  # agent frontmatter path shape: ".../companies/<co>/agents/<slug>/AGENT.md"
  # (legacy `agent.md` accepted for backwards compatibility).
  defp derive_slug(path) do
    parts = Path.split(path)

    case Enum.reverse(parts) do
      [name, slug | _] when name in ["AGENT.md", "agent.md"] ->
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

  # GEP-25 R26.2b — require `kind: agent/v1` in AGENT.md frontmatter.
  # The file-spec boundary already rejects `agent.md` (lowercase) and
  # non-canonical path shapes; this is the parser-level boundary that
  # stops an AGENT.md without a `kind:` at all from booting. Pre-1.0
  # "no kid gloves" — no fallback readers, no deprecation window.
  defp require_kind(meta) do
    case Map.get(meta, "kind") do
      "agent/v1" -> :ok
      nil -> {:error, {:missing_kind, "agent/v1"}}
      other -> {:error, {:wrong_kind, "agent/v1", other}}
    end
  end

  # Extract company slug from ".../companies/<co>/agents/<slug>/AGENT.md".
  # If the path doesn't fit that shape we default to "" — the company is
  # usually provided explicitly by the caller (AgentSupervisor will override
  # it). Tests that rely on path-derived company use the canonical layout.
  # Both `AGENT.md` (canonical) and `agent.md` (legacy) are accepted.
  defp derive_company(path) do
    parts = path |> Path.split() |> Enum.reverse()

    case parts do
      [name, _slug, "agents", company | _] when name in ["AGENT.md", "agent.md"] ->
        {:ok, company}

      _ ->
        {:ok, ""}
    end
  end

  defp validate_provider(nil), do: {:error, {:invalid_provider, ""}}

  defp validate_provider(provider) when is_binary(provider) do
    # Still string-compare (no `String.to_atom/1` on user input; T-03-15).
    # The allowlist is the union of the live registry's provider names
    # (config-driven via `priv/providers/*.toml` + `providers.toml`) and
    # `@fallback_providers` for the no-registry-yet case.
    if provider in known_providers() do
      {:ok, provider}
    else
      {:error, {:invalid_provider, provider}}
    end
  end

  # Non-binary providers (YAML number, list, map) should report a safe
  # shape tag rather than leak the struct contents via `inspect/1`
  # into an error tuple that callers may surface to the Director.
  defp validate_provider(other), do: {:error, {:invalid_provider, shape_tag(other)}}

  # Union of registry-loaded provider names and the static fallback.
  # If the registry Agent isn't running (common in unit tests) we fall
  # back cleanly without raising; if it's running but empty we still
  # accept the built-ins.
  defp known_providers do
    registry =
      try do
        Glorbo.CLI.Registry.list() |> Enum.map(& &1.name)
      catch
        :exit, _ -> []
      end

    Enum.uniq(registry ++ @fallback_providers)
  end

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

  # Native providers make real HTTPS requests to their endpoint from
  # inside the harness, so `network: loopback` is structurally
  # impossible. Reject it at parse time instead of letting dispatch
  # fail later.
  defp validate_network(nil, provider, :native),
    do: {:error, {:native_provider_requires_network, provider}}

  defp validate_network("", provider, :native),
    do: {:error, {:native_provider_requires_network, provider}}

  defp validate_network("loopback", provider, :native),
    do: {:error, {:native_provider_requires_network, provider}}

  defp validate_network(nil, _provider, _kind), do: {:ok, :loopback}
  defp validate_network("", _provider, _kind), do: {:ok, :loopback}

  defp validate_network(raw, _provider, _kind) when is_binary(raw) do
    case Map.fetch(@network_map, raw) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_network, raw}}
    end
  end

  defp validate_network(other, _provider, _kind),
    do: {:error, {:invalid_network, shape_tag(other)}}

  defp provider_kind(provider_name) when is_binary(provider_name) do
    registry_kinds =
      try do
        Glorbo.CLI.Registry.list()
        |> Map.new(fn provider -> {provider.name, provider.kind} end)
      catch
        :exit, _ -> %{}
      end

    Map.get(registry_kinds, provider_name, Map.get(@fallback_provider_kinds, provider_name, :cli))
  end

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
    do: {:error, {:invalid_skill_name, shape_tag(other)}}

  # Map a non-binary value to an opaque shape tag the Director can
  # safely see without leaking struct/PID/path contents from
  # `inspect/1`. Callers reach this only when the YAML was valid but
  # the value has the wrong TYPE — which is what the caller cares
  # about anyway.
  defp shape_tag(v) when is_atom(v), do: {:atom, v}
  defp shape_tag(v) when is_integer(v), do: :integer
  defp shape_tag(v) when is_float(v), do: :float
  defp shape_tag(v) when is_list(v), do: :list
  defp shape_tag(v) when is_map(v), do: :map
  defp shape_tag(v) when is_tuple(v), do: :tuple
  defp shape_tag(v) when is_pid(v), do: :pid
  defp shape_tag(v) when is_reference(v), do: :reference
  defp shape_tag(v) when is_function(v), do: :function
  defp shape_tag(nil), do: nil
  defp shape_tag(_), do: :unknown

  # Heartbeat: cron string or nil. Validation of cron SHAPE is the Scheduler's
  # job at register-time; here we only check it's a binary or absent.
  defp validate_heartbeat(nil), do: {:ok, nil}
  defp validate_heartbeat(""), do: {:ok, nil}

  defp validate_heartbeat(value) when is_binary(value) do
    # #233 — compile NL phrases ("every morning at 9am") to cron before
    # the Scheduler sees them. Unknown inputs pass through as literals;
    # Scheduler.register/3 surfaces invalid cron with its own error.
    case Glorbo.Schedule.NL.compile(value) do
      {:ok, cron} -> {:ok, cron}
      :error -> {:ok, value}
    end
  end

  defp validate_heartbeat(_), do: {:ok, nil}

  # Budget: positive integer cents or nil (no cap → no hard-stop).
  defp validate_budget(budget_map, legacy_cents) when is_map(budget_map) do
    case parse_budget_monthly_usd(Map.get(budget_map, "monthly_usd")) do
      {:ok, nil} -> validate_budget(nil, legacy_cents)
      result -> result
    end
  end

  defp validate_budget(_budget_map, legacy_cents), do: parse_legacy_budget_cents(legacy_cents)

  defp parse_legacy_budget_cents(nil), do: {:ok, nil}
  defp parse_legacy_budget_cents(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp parse_legacy_budget_cents(_), do: {:ok, nil}

  defp parse_budget_monthly_usd(nil), do: {:ok, nil}
  defp parse_budget_monthly_usd(v) when is_integer(v) and v >= 0, do: {:ok, v * 100}
  defp parse_budget_monthly_usd(v) when is_float(v) and v >= 0, do: {:ok, round(v * 100)}

  defp parse_budget_monthly_usd(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {amount, ""} when amount >= 0 -> {:ok, round(amount * 100)}
      _ -> {:ok, nil}
    end
  end

  defp parse_budget_monthly_usd(_), do: {:ok, nil}

  # Timeout: positive integer seconds, default 300 (D-06).
  defp validate_timeout(nil), do: {:ok, @default_timeout_seconds}
  defp validate_timeout(v) when is_integer(v) and v > 0, do: {:ok, v}
  defp validate_timeout(_), do: {:ok, @default_timeout_seconds}

  defp validate_http_timeout(nil), do: {:ok, @default_http_timeout_s}
  defp validate_http_timeout(v) when is_integer(v) and v > 0, do: {:ok, v}
  defp validate_http_timeout(_), do: {:ok, @default_http_timeout_s}

  defp validate_http_max_retries(nil), do: {:ok, @default_http_max_retries}
  defp validate_http_max_retries(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp validate_http_max_retries(_), do: {:ok, @default_http_max_retries}

  defp validate_web_fetch_timeout(nil), do: {:ok, @default_web_fetch_timeout_s}
  defp validate_web_fetch_timeout(v) when is_integer(v) and v > 0, do: {:ok, v}
  defp validate_web_fetch_timeout(_), do: {:ok, @default_web_fetch_timeout_s}

  defp validate_max_tool_calls_per_turn(nil), do: {:ok, @default_max_tool_calls_per_turn}

  defp validate_max_tool_calls_per_turn(v) when is_integer(v) and v > 0,
    do: {:ok, v}

  defp validate_max_tool_calls_per_turn(_), do: {:ok, @default_max_tool_calls_per_turn}

  # #248 T1-A — max_retries: non-negative integer. Default 2
  # (1 initial + 2 retries = 3 total attempts). Capped at 5 to
  # prevent runaway retry budgets; higher values get clamped.
  defp validate_max_retries(nil), do: {:ok, 2}
  defp validate_max_retries(n) when is_integer(n) and n >= 0, do: {:ok, min(n, 5)}
  defp validate_max_retries(_), do: {:ok, 2}

  # GEP-46 — max_concurrency: positive integer. Default 1 preserves the
  # historic single-instance behaviour. Capped at 32 so a typo
  # (`max_concurrency: 1000`) doesn't open the floodgates.
  defp validate_max_concurrency(nil), do: {:ok, 1}
  defp validate_max_concurrency(n) when is_integer(n) and n >= 1, do: {:ok, min(n, 32)}
  defp validate_max_concurrency(_), do: {:ok, 1}
end
