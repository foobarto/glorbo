defmodule Glorbo.Network.SmartClassifier do
  @moduledoc """
  GEP-23 smart-mode classifier (#287). Pure host-verdict logic for
  `Glorbo.Network.Proxy` when an agent's `egress.mode` is `:smart`.

  Two layers, composed:

    1. **Rule-based classification** — exact + wildcard match against
       the agent's `egress.allow` / `egress.deny` lists, plus GEP-23's
       baseline private-IP and ad-TLD heuristics.
    2. **LLM fallback** — hosts that don't match any rule get fed
       to a cheap LLM call with director-declared natural-language
       categories (`smart_allow:` / `smart_deny:` on AGENT.md). The
       classifier response is parsed into `:allow | :deny | :unknown`;
       malformed responses fall safe to `:unknown`.

  Phase 1 of the smart-mode rollout ships the pure functions here +
  the AGENT.md parser additions. Proxy wiring, per-company decision
  cache, director-sentinel fallback, and budget accounting land in
  later phases so each step has a small, testable blast radius.

  ## Public shape

      classify(host, egress_config, opts \\\\ []) ->
        {:allow, reason :: atom()}
        | {:deny, reason :: atom()}
        | {:unknown, reason :: atom()}

  The rule-based path never returns `:unknown`. `:unknown` means
  "the rules didn't speak; smart-mode caller must decide whether to
  invoke the LLM or fall through to a director approval sentinel."

  ## Dependency injection

  `:classify_fun` in `opts` swaps the LLM dispatch for tests. Default
  is `&__MODULE__.default_llm_classify/3` — a stub that returns
  `{:ok, :unknown, "-", "classifier not yet wired"}`. Wiring the real
  LLM to `Glorbo.Agent.Dispatch` is Phase 2.
  """

  alias Glorbo.Network.SmartClassifier

  # Ad-TLD denylist — GEP-23 baseline. Directors can add more hosts
  # to `egress.deny`; this covers the obvious commercial-tracker TLDs
  # that no legitimate agent workload should reach.
  @ad_tlds ~w(.ads. .doubleclick. .googlesyndication. .googleadservices.)

  @type verdict :: :allow | :deny | :unknown
  @type reason :: atom()
  @type egress_config :: %{
          optional(:mode) => :allow | :deny | :strict | :smart,
          optional(:allow) => [String.t()],
          optional(:deny) => [String.t()],
          optional(:smart_allow) => String.t(),
          optional(:smart_deny) => String.t(),
          optional(:smart_model) => String.t() | nil
        }

  @doc """
  Classify `host` against `egress_config`. Rule-based only — does
  not invoke the LLM. Use `smart_classify/3` for the full
  rule + LLM path.
  """
  @spec classify(String.t(), egress_config()) :: {verdict(), reason()}
  def classify(host, egress_config) when is_binary(host) and is_map(egress_config) do
    normalised = String.downcase(host)

    cond do
      match_list?(normalised, Map.get(egress_config, :deny, [])) ->
        {:deny, :denylist}

      # Threatmodel T8: private-IP rejection MUST precede the allowlist
      # check. If an operator or agent-supplied `allow` list contains a
      # private/loopback address ("127.0.0.1", "10.0.0.1", …) the proxy
      # would otherwise pass traffic through to host-local services,
      # defeating SSRF isolation. The private_ip?/1 invariant is
      # unconditional: no matter what the allowlist says, we never let
      # the sandbox reach the host's private network.
      private_ip?(normalised) ->
        {:deny, :private_ip}

      match_list?(normalised, Map.get(egress_config, :allow, [])) ->
        {:allow, :allowlist}

      ad_tld?(normalised) ->
        {:deny, :ad_tld}

      Map.get(egress_config, :mode, :allow) == :deny ->
        {:allow, :denylist_fallthrough}

      Map.get(egress_config, :mode, :allow) == :allow ->
        {:deny, :allowlist_fallthrough}

      true ->
        {:unknown, :no_rule_match}
    end
  end

  @doc """
  Full smart-mode classification: rule-based first, then LLM if
  `mode: :smart` and rules returned `:unknown`. Other modes never
  reach the LLM.

  Returns the rule verdict when decisive. When smart-mode rules
  return `:unknown`, calls `classify_fun.(host, smart_allow,
  smart_deny)` and maps its output to a verdict.

  The classify function must return one of:
    * `{:ok, :allow, category, rationale}` → `{:allow, :smart_allow}`
    * `{:ok, :deny, category, rationale}`  → `{:deny, :smart_deny}`
    * `{:ok, :unknown, _, _}`              → `{:unknown, :smart_unknown}`
    * `{:error, reason}`                   → `{:unknown, :smart_error}`
  """
  @spec smart_classify(String.t(), egress_config(), keyword()) ::
          {verdict(), reason()}
  def smart_classify(host, egress_config, opts \\ [])

  def smart_classify(host, egress_config, opts)
      when is_binary(host) and is_map(egress_config) do
    case classify(host, egress_config) do
      {:unknown, :no_rule_match} ->
        if Map.get(egress_config, :mode, :allow) == :smart do
          invoke_llm(host, egress_config, opts)
        else
          # strict mode: no rule, no LLM, caller surfaces as pending-
          # approval sentinel.
          {:unknown, :no_rule_match}
        end

      decisive ->
        decisive
    end
  end

  @doc """
  Build the classifier prompt (GEP-23 §Smart mode). Pure function;
  exposed for auditing + testing.
  """
  @spec build_prompt(String.t(), String.t(), String.t()) :: String.t()
  def build_prompt(host, smart_allow, smart_deny) when is_binary(host) do
    safe_host = sanitise_host(host)

    allow_line = if smart_allow == "", do: "(none declared)", else: smart_allow
    deny_line = if smart_deny == "", do: "(none declared)", else: smart_deny

    """
    You are a URL safety classifier. Decide whether the host is safe
    to connect to for an autonomous agent working on behalf of a
    company.

    Classify this host:
      #{safe_host}

    Allowed categories (match → allow):
      #{allow_line}

    Denied categories (match → deny):
      #{deny_line}

    Respond with ONE line in this exact format:
      <verdict>|<category>|<rationale>

    Where:
      <verdict>  = allow | deny | unknown
      <category> = one matching category from above, or "-" for unknown
      <rationale> = one short English sentence

    No other output.
    """
  end

  @doc """
  Parse the LLM response into `{:ok, verdict, category, rationale}`
  or `{:error, reason}`. Rejects any response that doesn't match
  the exact pipe-delimited format — this is the prompt-injection
  defence (GEP-23 §Smart mode).
  """
  @spec parse_response(String.t()) ::
          {:ok, verdict(), String.t(), String.t()} | {:error, atom()}
  def parse_response(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    if String.contains?(trimmed, "\n") do
      # Multi-line responses are a prompt-injection red flag. The
      # classifier prompt explicitly asks for a single line; anything
      # else is rejected.
      {:error, :malformed_response}
    else
      parse_single_line(trimmed)
    end
  end

  def parse_response(_), do: {:error, :malformed_response}

  defp parse_single_line(line) do
    case String.split(line, "|", parts: 3) do
      [verdict_raw, category, rationale]
      when byte_size(verdict_raw) > 0 and
             byte_size(category) > 0 and
             byte_size(rationale) > 0 ->
        case normalise_verdict(verdict_raw) do
          {:ok, verdict} ->
            {:ok, verdict, String.trim(category), String.trim(rationale)}

          :error ->
            {:error, :bad_verdict}
        end

      _ ->
        {:error, :malformed_response}
    end
  end

  @doc """
  Stub LLM classifier — returns `{:ok, :unknown, "-", "classifier
  not yet wired"}`. Replaced via `classify_fun:` option in Phase 2
  once the real dispatch integration is in place.
  """
  @spec default_llm_classify(String.t(), String.t(), String.t()) ::
          {:ok, verdict(), String.t(), String.t()} | {:error, atom()}
  def default_llm_classify(_host, _smart_allow, _smart_deny) do
    {:ok, :unknown, "-", "classifier not yet wired"}
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # Exact or single-level wildcard match. `*.example.com` matches
  # `foo.example.com` and `bar.baz.example.com` but not bare
  # `example.com`. Bare `example.com` matches exact only.
  defp match_list?(host, list) when is_list(list) do
    Enum.any?(list, &host_matches?(host, &1))
  end

  defp host_matches?(host, "*." <> suffix) do
    String.ends_with?(host, "." <> suffix)
  end

  defp host_matches?(host, pattern), do: host == pattern

  # Treat any RFC1918 / loopback / link-local literal as private.
  # We never accept a private-IP destination from the sandbox: the
  # proxy runs in a netns without a route to the host's private
  # network.
  defp private_ip?(host) do
    cond do
      host == "localhost" -> true
      host == "127.0.0.1" -> true
      host == "::1" -> true
      String.starts_with?(host, "127.") -> true
      String.starts_with?(host, "10.") -> true
      String.starts_with?(host, "192.168.") -> true
      String.starts_with?(host, "169.254.") -> true
      String.match?(host, ~r/^172\.(1[6-9]|2\d|3[0-1])\./) -> true
      true -> false
    end
  end

  defp ad_tld?(host) do
    Enum.any?(@ad_tlds, &String.contains?("." <> host <> ".", &1))
  end

  # Strip the host to alphanumerics + dots + hyphens before rendering
  # into the classifier prompt. Caps at 253 chars (DNS max).
  defp sanitise_host(host) do
    cleaned =
      host
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9.\-]/, "")

    binary_part(cleaned, 0, min(byte_size(cleaned), 253))
  end

  defp normalise_verdict(raw) do
    case raw |> String.trim() |> String.downcase() do
      "allow" -> {:ok, :allow}
      "deny" -> {:ok, :deny}
      "unknown" -> {:ok, :unknown}
      _ -> :error
    end
  end

  defp invoke_llm(host, egress_config, opts) do
    classify_fun = Keyword.get(opts, :classify_fun, &SmartClassifier.default_llm_classify/3)
    smart_allow = Map.get(egress_config, :smart_allow, "")
    smart_deny = Map.get(egress_config, :smart_deny, "")

    case classify_fun.(host, smart_allow, smart_deny) do
      {:ok, :allow, _cat, _rationale} -> {:allow, :smart_allow}
      {:ok, :deny, _cat, _rationale} -> {:deny, :smart_deny}
      {:ok, :unknown, _cat, _rationale} -> {:unknown, :smart_unknown}
      {:error, _reason} -> {:unknown, :smart_error}
      _ -> {:unknown, :smart_error}
    end
  end
end
