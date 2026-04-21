---
title: Per-provider advanced model params — knob landscape
date: 2026-04-21
status: research
source_task: "#316"
feeds: "Draft GEP for per-task / per-agent advanced-params support"
---

# Per-provider advanced model params

Research done to inform a future GEP-27-style feature: let directors
set `temperature`, `reasoning_effort`, `max_tokens`, `thinking` budget,
etc. per-task or per-agent, and have Glorbo plumb them through to
whichever provider the agent is pinned to.

This doc captures **where each supported provider puts these knobs
today** — CLI flag vs config file vs env var — so the implementation
plan can pick the right plumbing shape per provider.

Providers surveyed: `claude-code`, `codex`, `gemini-cli`, `opencode`,
`hermes`, `pi`. Matches the TOML set under `priv/providers/`.

---

## 1. claude-code (Anthropic Claude Code CLI)

**Knobs available:**

- `--effort <low|medium|high|xhigh|max>` — CLI flag; maps to
  Anthropic `effort` param.
- `--fallback-model <model>` — CLI flag (printing mode only).
- `--max-budget-usd <amount>` — CLI cost ceiling (not a sampling
  knob but in the family).
- `--model <model>` — already plumbed.
- `--betas <headers...>` — CLI flag; opts into beta sampling
  features.
- `MAX_THINKING_TOKENS=<N>` — env var; pre-4.7 thinking-budget
  override.
- `effortLevel`, `alwaysThinkingEnabled` — `~/.claude/settings.json`
  keys (loadable via `--settings <file-or-json>`).
- `--settings '{"...":"..."}'` — inline JSON override; the cleanest
  per-task knob.
- `--system-prompt` / `--append-system-prompt` — prompt shape,
  not sampling.

**No native `--temperature` / `--top-p` / `--seed` flag.** Claude
Opus 4.7 rejects non-default temp/top_p/top_k; Anthropic is
discouraging those. `effort` + `MAX_THINKING_TOKENS` are the
supported knobs.

**Glorbo-integration note:** add `{effort}`, `{max_budget_usd}`,
`{settings_json}` placeholders to the TOML `args`; fragment
`--effort {effort} --settings {settings_json}`. Dispatcher injects
`MAX_THINKING_TOKENS` into `[env]` from frontmatter.

**Unknowns:** whether `--settings '{"temperature":0.2}'` actually
reaches the API (docs silent); needs a probe against a real
invocation.

---

## 2. codex (OpenAI Codex CLI)

**Knobs available (all via `-c <dotted.path>=<toml-value>`):**

- `-c model_reasoning_effort=minimal|low|medium|high`
- `-c model_reasoning_summary=auto|concise|detailed|none`
- `-c model_verbosity=low|medium|high` (gpt-5 family)
- `-c model_max_output_tokens=<int>`, `-c model_context_window=<int>`
- `-c model="..."` / `-c model_provider="..."`
- `--output-schema <FILE>` — JSON-schema-constrained output.
- `-p/--profile <name>` — named preset in `config.toml`.
- **No documented** `temperature`, `top_p`, or `seed` — reasoning-
  effort supersedes them for gpt-5/o-series.

**Glorbo-integration note:** cleanest wiring is a
`reasoning_effort` + `verbosity` + `max_output_tokens` placeholder
trio emitted as repeated `-c key=value` fragments. Glorbo already
passes `-c model=...` implicitly, so `-c` as a repeated-arg
template is the right abstraction.

**Unknowns:** Codex CLI config evolves quickly; the full key list
should be re-verified against the installed Codex version at build
time (not hardcoded).

---

## 3. gemini-cli (Google Gemini CLI)

**Knobs available:**

- **No CLI flags** for temperature/topP/thinking in the 2026-04
  build.
- All sampling lives in `~/.gemini/settings.json` under
  `modelConfigs.customAliases[<alias>].modelConfig
  .generateContentConfig.*`:
    - `.temperature`, `.topP`, `.topK`, `.maxOutputTokens`
    - `.thinkingConfig.thinkingBudget`,
      `.thinkingConfig.includeThoughts`,
      `.thinkingConfig.thinkingLevel`
      (Gemini 3: `LOW|MEDIUM|HIGH|NONE`)
    - `.seed` (accepted by underlying Google GenAI SDK; not
      explicit in gemini-cli docs).
- An alias is selected by passing its name as `-m <alias>`. Knob
  wiring: pre-write an alias in `settings.json`, then pass
  `-m alias-name`.

**Glorbo-integration note:** Glorbo must synthesize a per-
invocation `settings.json` fragment. Current `ro` auth-bind of
`~/.gemini` blocks this. Clean fix: new `{gemini_settings_json}`
template rendered into a workspace-local
`/workspace/.gemini/settings.json` with `rw` mode, replacing the
host-auth-bind for gemini-cli.

**Unknowns:** whether `seed` round-trips through the CLI layer
(SDK supports it; CLI may strip). Tracked upstream:
google-gemini/gemini-cli issue #5280.

---

## 4. opencode

**Knobs available (all in `opencode.json` or agent markdown
frontmatter, NO CLI flags):**

- `agent.<name>.temperature` (0.0–1.0)
- `agent.<name>.top_p` (0.0–1.0)
- `agent.<name>.maxTokens`
- `agent.<name>.thinking` (bool/object, provider-dependent)
- `agent.<name>.reasoningEffort` (OpenAI-style: `low|medium|high`)
- `agent.<name>.textVerbosity`
- `agent.<name>.providerOptions` (pass-through blob)
- `agent.<name>.steps` (agentic-loop cap)

`opencode run` CLI only exposes `-m <provider/model>`; no
sampling flags.

**Glorbo-integration note:** same shape as gemini-cli — Glorbo
must write a workspace-scoped `opencode.json` agent fragment.
Currently `~/.config/opencode/` is ro-mounted; needs a rw overlay
at `/workspace/.config/opencode/opencode.json` merging host
providers + generated agent block. Template key
`{opencode_agent_json}`.

**Unknowns:** no `seed` documented; precedence rules for per-run
vs per-agent overrides are thin.

---

## 5. hermes

**Knobs available:**

- `hermes chat --model <id>` (e.g. `anthropic/claude-sonnet-4`)
- `--provider <name>` (enum)
- `--max-turns N` — tool-calling iterations, not sampling.
- `-t/--toolsets`, `-s/--skills`, `-Q/--quiet`, `--yolo`,
  `--checkpoints`.
- `hermes config set <key> <value>` — persistent config; keys
  include `model` but sampling keys are undocumented in `--help`.
- `hermes config edit` opens `$EDITOR` on the config file.

**No `--temperature`, `--top-p`, `--reasoning-effort`, `--seed`,
or `--thinking` flags in the CLI.** Hermes is a router; sampling
appears fixed per-provider.

**Glorbo-integration note:** no short-term change — hermes' TOML
stays sampling-less. Optionally wire `{max_turns}` via a new
`--max-turns {max_turns}` fragment for agentic-loop caps.

**Unknowns:** whether `hermes config set sampling.temperature …`
or similar nested keys exist; only probing `hermes config --help`
against the installed binary would confirm.

---

## 6. pi

**Knobs available:**

- `--model <pattern>` including `:<thinking>` suffix shorthand
  (e.g. `sonnet:high`).
- `--thinking <off|minimal|low|medium|high|xhigh>` — CLI flag.
- `--provider <name>`, `--api-key`.
- `--mode <text|json|rpc>` — output format, not sampling.
- `--tools`, `--system-prompt`, `--append-system-prompt`.

**No `--temperature`, `--top-p`, `--max-tokens`, or `--seed`
flags.** Like claude-code, pi abstracts sampling into `--thinking`
(and the `:high` model-suffix shorthand).

**Glorbo-integration note:** add `{thinking}` placeholder; args
fragment `--thinking {thinking}`. Model-suffix form
(`--model {model}:{thinking}`) is an alternative but less clean
to template.

**Unknowns:** no documented config file path for per-provider
sampling defaults; `~/.pi/` layout not probed.

---

## Cross-provider summary for a future GEP

Two families emerge:

- **Abstracted-effort family** — `claude-code`, `codex`, `pi`.
  Expose `effort` / `reasoning_effort` / `thinking` as a 3–5-
  level enum. Plumb as a single `{effort}` placeholder, mapped
  per-provider.

- **Raw-sampling family** — `opencode`, `gemini-cli`. Expose
  `temperature`, `top_p`, `max_tokens`, optional `seed`. Settable
  **only** via file overlay, not CLI flags. Glorbo needs a
  generated-config-file mechanism:
    - new TOML section `generated_configs = [{ path, template }]`
    - replace the blanket `ro` auth-bind for these providers with
      a writable overlay
    - dispatcher renders the overlay from task + agent frontmatter
      before each invocation

- **Sampling-inert** — `hermes` is a routing layer; advanced
  params don't apply. Document that the knob is ignored for
  hermes agents.

## Proposed Glorbo surface (rough cut)

Per-agent (`AGENT.md` frontmatter):
```yaml
model_params:
  effort: medium           # for effort-family providers
  temperature: 0.3         # for sampling-family providers
  max_tokens: 8192
  thinking: medium         # alias for effort where applicable
  seed: 42                 # opt-in determinism where supported
```

Per-task (`task.md` frontmatter) — same keys override per-agent.
Precedence: task > agent > provider default.

The dispatcher consults the provider's TOML "params schema" section
(new) to decide which placeholders to substitute into which args
fragments or which overlay files to render.

## Next steps

1. Probe each installed provider's CLI to confirm the live
   capability matches the docs (fast — one `--help` + one
   real-world invocation per provider).
2. Draft GEP-27 "Per-task / per-agent advanced model params"
   with this doc as reference material.
3. Land a provider-agnostic `Glorbo.Agent.Dispatch.ParamResolver`
   that merges task/agent/provider-default layers and emits the
   substitution map the TOML renderer consumes.
