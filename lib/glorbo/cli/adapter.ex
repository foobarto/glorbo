defmodule Glorbo.CLI.Adapter do
  @moduledoc """
  Uniform behaviour implemented by each supported CLI provider (D-41..D-43).

  Three v0.0.1 adapters implement this:

    * `Glorbo.CLI.Adapter.ClaudeCode` — `claude --print`
    * `Glorbo.CLI.Adapter.GeminiCli` — `gemini -p ... --output-format json`
    * `Glorbo.CLI.Adapter.Codex` — `codex exec --json`

  `Glorbo.Agent.Dispatch` routes a task through the adapter resolved from
  `Glorbo.Agent.Spec.provider`. Adapter implementations are pure — no IO
  beyond `System.find_executable/1` in `binary/0` and filesystem inspection
  in `parse_usage/1`.

  ## Per-agent auth isolation

  CLI tools manage their own OAuth credentials in `$HOME/.claude/`,
  `$HOME/.gemini/`, `$HOME/.codex/`. Plan 03-05 binds each provider's auth
  dir read-only into the sandbox and uses `env/2`'s returned env vars to
  redirect session writes into the agent's workspace so sessions don't mix
  with the Director's. This keeps auth shared (one login per provider)
  while isolating session history per-agent.
  """

  @type invocation_env :: %{optional(String.t()) => String.t()}
  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          model: String.t() | nil
        }

  @type usage_location ::
          {:jsonl_dir, String.t()}
          | {:jsonl_file, String.t()}
          | :stdout

  @type usage_source ::
          {:jsonl_file, String.t()}
          | {:stdout, binary()}

  @doc """
  Return the absolute path to the CLI binary on this host, or `nil` if the
  binary is not on `PATH`. Dispatch uses a `nil` return to emit
  `provider.unavailable` and abort the dispatch before any skills are
  materialised.
  """
  @callback binary() :: String.t() | nil

  @doc """
  Build the argv tail passed to the CLI binary (everything after the binary
  path itself; the bwrap prefix is added by Plan 03-05's `Sandbox.Bwrap`).

    * `spec` — `Glorbo.Agent.Spec` struct (provides `model`, etc.)
    * `prompt_path` — absolute path to the task-prompt file written by
      Dispatch (kept on disk for audit; per D-03 the prompt is also
      streamed via stdin at dispatch-time).
    * `opts` — adapter-specific overrides (reserved for future use).
  """
  @callback args(
              spec :: Glorbo.Agent.Spec.t(),
              prompt_path :: String.t(),
              opts :: keyword()
            ) :: [String.t()]

  @doc """
  Return env-var overrides for this adapter. Plan 03-05's Bwrap injects
  these via `--setenv` on top of the sandbox's base env. Values typically
  redirect session/state directories into the agent workspace (`CLAUDE_CONFIG_DIR`,
  `CODEX_HOME`, etc.).
  """
  @callback env(spec :: Glorbo.Agent.Spec.t(), workspace :: String.t()) ::
              invocation_env()

  @doc """
  Return the filesystem location where usage telemetry will land AFTER the
  invocation completes (if any). Dispatch inspects this path post-run and
  passes the resolved content (or the captured stdout bytes) to
  `parse_usage/1`.

    * `{:jsonl_dir, path}` — directory containing session JSONL file(s);
      Dispatch picks the most-recent `*.jsonl` in the dir.
    * `{:jsonl_file, path}` — an exact filename (unused by the three
      v0.0.1 adapters but available for future providers).
    * `:stdout` — usage is parsed from the captured stdout buffer.
  """
  @callback usage_path(spec :: Glorbo.Agent.Spec.t(), workspace :: String.t()) ::
              usage_location()

  @doc """
  Parse the usage telemetry for a completed invocation.

    * `{:jsonl_file, path}` — adapter reads the file with `File.stream!/1`
      and extracts totals.
    * `{:stdout, blob}` — adapter decodes JSON from the captured stdout
      buffer.

  Returns `{:ok, usage()}` on success. Errors (`:enoent`,
  `:json_decode_error`, `:no_stats`, `:no_token_count`, …) indicate absent
  or malformed telemetry — Dispatch records zero tokens for the invocation
  and emits `usage.parse_error` (conservative per Pitfall 5).
  """
  @callback parse_usage(usage_source()) :: {:ok, usage()} | {:error, term()}
end
