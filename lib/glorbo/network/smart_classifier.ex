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

  # Treat any RFC1918 / loopback / link-local / unspecified / ULA
  # literal as private. We never accept a private-IP destination from
  # the sandbox: the proxy runs in a netns without a route to the
  # host's private network.
  #
  # Coverage expanded in round-4 after opencode flagged several
  # missing shapes (`0.0.0.0`, `::`, `fc00::/7` ULA, `fe80::/10`
  # link-local, `::ffff:...` IPv4-mapped).
  defp private_ip?(host) do
    cond do
      # Loopback + unspecified aliases.
      host == "localhost" ->
        true

      host == "127.0.0.1" ->
        true

      host == "0.0.0.0" ->
        true

      # IPv6 loopback / unspecified, including common non-canonical
      # forms (`::0001`, `0:0:0:0:0:0:0:1`, with or without brackets).
      ipv6_loopback_or_unspec?(host) ->
        true

      # IPv4-mapped IPv6 loopback `::ffff:127.0.0.1` or any
      # `::ffff:<rfc1918>`.
      String.starts_with?(host, "::ffff:") and
          private_ip?(String.replace_leading(host, "::ffff:", "")) ->
        true

      # IPv4 RFC1918 + loopback + link-local.
      String.starts_with?(host, "127.") ->
        true

      String.starts_with?(host, "10.") ->
        true

      String.starts_with?(host, "192.168.") ->
        true

      String.starts_with?(host, "169.254.") ->
        true

      String.match?(host, ~r/^172\.(1[6-9]|2\d|3[0-1])\./) ->
        true

      # IPv6 link-local fe80::/10 and ULA fc00::/7 (covers fc and fd).
      ipv6_link_local?(host) ->
        true

      ipv6_ula?(host) ->
        true

      # Threatmodel wave 26: `inet_aton`-legacy integer-encoded IPv4
      # forms (decimal `2852039166`, hex `0xa9fea9fe`, octal-dotted
      # `0251.0376.0251.0376`, hybrid short-form `169.16689662`, etc.)
      # all resolve via `:inet.getaddrs` to the same 4-byte address as
      # their canonical dotted form — but the string-prefix checks above
      # only catch the canonical shape. An attacker can encode
      # `169.254.169.254` (AWS metadata) as `2852039166` to bypass
      # `private_ip?` and reach link-local from a smart-mode classifier
      # cache hit / denylist-fallthrough allow verdict. (DNS-rebind
      # defense in `proxy.ex` still catches the *resolved* IP for the
      # data path, but the classifier's T8 invariant — "no private IP
      # destination, ever" — must hold at THIS layer too: future
      # refactors could remove Layer 2, and a misleading `:allow`
      # verdict pollutes audit / smart-mode cache.)
      integer_encoded_private_ipv4?(host) ->
        true

      true ->
        false
    end
  end

  # A host is "numeric-IP-shaped" if every dot-separated segment is a
  # plain decimal, an `0x`-prefixed hex literal, or a leading-zero
  # octal literal — i.e. the encodings BSD `inet_aton` accepts beyond
  # the strict dotted-decimal form. Bounded check; no DNS.
  @numeric_ip_re ~r/^(0[xX][0-9a-fA-F]+|0[0-7]+|[1-9][0-9]*|0)(\.(0[xX][0-9a-fA-F]+|0[0-7]+|[1-9][0-9]*|0)){0,3}$/

  defp integer_encoded_private_ipv4?(host) do
    with true <- String.match?(host, @numeric_ip_re),
         # `:inet.getaddrs/3` honours `inet_aton`'s legacy parser for
         # integer-encoded forms WITHOUT performing DNS — the resolution
         # is purely local, even with a tiny timeout. (Confirmed
         # empirically; DNS labels with letters/dashes won't match the
         # regex above so we never even reach this call for them.)
         {:ok, [tup | _]} <- :inet.getaddrs(String.to_charlist(host), :inet, 0) do
      ipv4_tuple_private?(tup)
    else
      _ -> false
    end
  end

  defp ipv4_tuple_private?({0, _, _, _}), do: true
  defp ipv4_tuple_private?({127, _, _, _}), do: true
  defp ipv4_tuple_private?({10, _, _, _}), do: true
  defp ipv4_tuple_private?({172, b, _, _}) when b in 16..31, do: true
  defp ipv4_tuple_private?({192, 168, _, _}), do: true
  defp ipv4_tuple_private?({169, 254, _, _}), do: true
  defp ipv4_tuple_private?({100, b, _, _}) when b in 64..127, do: true
  defp ipv4_tuple_private?(_), do: false

  defp ipv6_loopback_or_unspec?(host) do
    normal = host |> String.trim_leading("[") |> String.trim_trailing("]")

    normal in [
      "::",
      "::1",
      "0:0:0:0:0:0:0:0",
      "0:0:0:0:0:0:0:1"
    ]
  end

  defp ipv6_link_local?(host) do
    normal = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    # fe80:: / 10 — any of fe80, fe81 .. febf.
    String.match?(normal, ~r/^fe[89ab][0-9a-f]:/)
  end

  defp ipv6_ula?(host) do
    normal = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()
    String.match?(normal, ~r/^f[cd][0-9a-f]{2}:/)
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
