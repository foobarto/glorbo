# Base allowlist of hostnames for `network: api-only` agents (D-16, D-17).
#
# Verified: 2026-04-16. Re-verify before each Glorbo release; upstream endpoint
# lists drift as providers add/retire regions. Additions MUST be reviewed for
# threat-model implications (adding a host = widening the escape surface).
#
# Consumed read-only by `Glorbo.Network.Proxy` (Plan 03-05). In v0.0.1 this
# acts as an advisory allowlist enforced via `HTTPS_PROXY` env var — a
# motivated agent ignoring the env var can bypass it. Netns + nftables is the
# hardening iteration.
#
# Sources (2026-04-16):
#   * claude-code: https://code.claude.com/docs/en/network-config
#   * gemini-cli : Google OAuth + Generative Language + AI Platform endpoints
#   * codex      : OpenAI API + auth endpoints
import Config

config :glorbo, :network_policy, %{
  api_only_base_allowlist: %{
    "claude-code" =>
      ~w(api.anthropic.com claude.ai platform.claude.com sentry.io statsig.anthropic.com),
    "gemini-cli" =>
      ~w(generativelanguage.googleapis.com oauth2.googleapis.com accounts.google.com aiplatform.googleapis.com cloudcode-pa.googleapis.com),
    "codex" => ~w(api.openai.com auth.openai.com chatgpt.com)
  }
}
