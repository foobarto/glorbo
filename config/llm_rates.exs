# Per-{provider, model} USD-per-million-tokens rate table (D-30).
#
# Verified: 2026-04-16. Re-verify before each Glorbo release; out-of-date rates
# produce quiet undercounting (user-accepted tradeoff per D-30 — Glorbo owns
# the mapping and returns 0 for missing entries rather than crashing dispatch).
#
# Sources (2026-04-16 snapshot):
#   * claude-opus-4-6  : Anthropic pricing page, 2026-Q2
#   * claude-sonnet-4-5: Anthropic pricing page, 2026-Q2
#   * gemini-2.5-pro   : Google AI pricing page
#   * gemini-2.5-flash : Google AI pricing page
#   * gpt-5            : OpenAI pricing page (estimated from gpt-4-turbo tier)
#   * o3-mini          : OpenAI pricing page
#
# Units: USD per million tokens (Mtok). Input/output rates are always distinct
# (output is typically 4-5x input). Consumed by `Glorbo.Budget.Ledger.compute_cost_cents/4`.
import Config

config :glorbo, :llm_rates, %{
  "claude-code" => %{
    "claude-opus-4-6" => %{input_usd_per_mtok: 15.00, output_usd_per_mtok: 75.00},
    "claude-sonnet-4-5" => %{input_usd_per_mtok: 3.00, output_usd_per_mtok: 15.00}
  },
  "gemini-cli" => %{
    "gemini-2.5-pro" => %{input_usd_per_mtok: 1.25, output_usd_per_mtok: 10.00},
    "gemini-2.5-flash" => %{input_usd_per_mtok: 0.30, output_usd_per_mtok: 2.50}
  },
  "codex" => %{
    "gpt-5" => %{input_usd_per_mtok: 10.00, output_usd_per_mtok: 30.00},
    "o3-mini" => %{input_usd_per_mtok: 3.00, output_usd_per_mtok: 12.00}
  }
}
