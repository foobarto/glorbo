---
gep: 0039
title: "Configurable TUI keybinding schemes — Emacs, Vim, VS Code"
author: Glorbo Maintainers <security@example.invalid>
status: Placeholder
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Placeholder
    note: |
      Reserved during the GEP-37 review pass. User's framing: Glorbo
      is "single user per instance" but targets many directors
      running their own instances, so preference diversity across
      editor lineage (Emacs / Vim / VS Code) is real even if no
      single instance needs multiple schemes simultaneously.
      Placeholder captures the design space; implementation blocked
      on "someone asks for it."
requires: [37]
see-also: [19, 30]
---

# GEP-39: Configurable TUI keybinding schemes — Emacs, Vim, VS Code

## Problem

GEP-37 ships the `glorbo tui` with a single keybinding scheme —
Emacs-flavoured, chosen because the current Director is an Emacs
user. D10 in GEP-37 rejected dual-scheme shipping with this
rationale: "two keybinding schemes means two test matrices, two
documentation pages, and continuous drift between them for zero
current benefit (single known user)."

That rationale is correct at GEP-37's scope (one known user) but
evaporates as Glorbo's product vision expands: each Glorbo
instance is single-user, yet Glorbo as a product targets many
directors running their own instances. Those directors come from
different editor lineages. An Emacs-only TUI is friendly to the
current user and hostile to the vim and VS Code directors who
will follow.

## Goals

- Let the Director pick a keybinding scheme on startup — built-in
  options are **Emacs** (default, inherited from GEP-37), **Vim**
  (modal, `j/k/y/n`, `g<letter>` prefixes, `:` ex-mode), and
  **VS Code** (Ctrl-chord heavy, `Ctrl+Shift+P` command palette,
  arrow-key motion).
- Keep one canonical **action registry** inside `Glorbo.Tui` — a
  flat list of logical actions (`:view.overview`, `:list.next`,
  `:composer.submit`, `:approval.accept`, …). Schemes are
  modules mapping `action → key_sequence`; the runtime only
  speaks action names.
- Support switching schemes without a rebuild — a single config
  line in `~/.glorbo/config.md` (or equivalent), runtime reloads
  the keymap at startup.
- Preserve GEP-37's IRC slash-command convention across all
  schemes. `/dispatch`, `/approve`, etc. in the composer are
  scheme-independent — they are text input, not keybinding.

## Non-goals

- **No user-authored DIY keymaps.** The complexity cost of
  accepting arbitrary user-defined chords (edge cases, CI
  reproducibility, "my chord doesn't fire" support burden) is
  not worth it at pre-1.0. Ship three curated schemes instead.
  A future GEP can revisit once demand is clear and the
  action-registry shape has stabilised.
- **No web-UI keybinding theming.** GEP-37 is TUI-only and this
  GEP inherits that scope. Web UI uses its current
  `ApprovalQueueLive` `j/k/y/n` shortcuts (shipped under GEP-19
  / GEP-20); any Emacs-flavoured web-UI pass is its own GEP.
- **No per-view rebinding.** Each scheme maps *global* actions;
  per-view key overrides would multiply the schemes by the view
  count and drown the "three curated schemes" model.
- **No runtime scheme-switch hotkey.** You pick one at startup.
  Mid-session switching would require teardown/rebuild of every
  view's keymap binding table; not worth the implementation
  surface.
- **Not a re-open of GEP-37 D10.** GEP-37 still ships one
  scheme as its default (Emacs). GEP-39 extends the TUI with
  *additional* schemes without re-deciding GEP-37's choice of
  default.

## Design direction (sketch — placeholder, not a commitment)

The substantive design is deferred until implementation demand
arrives. Rough sketch so a later Draft knows where to start:

1. **Action registry.** `Glorbo.Tui.Actions` — an enum-like
   module listing every logical action as an atom, with a
   human-readable description. Schemes never reference physical
   keys outside their own map.
2. **Scheme modules.** `Glorbo.Tui.Keybindings.Emacs`,
   `.Vim`, `.VSCode` — each exposes `bindings/0` returning a
   `%{action_atom => key_sequence}` map. Missing actions fall
   back to a trailing default.
3. **Config wiring.** `config.md` (or `~/.glorbo/config.md` —
   see GEP-25 config/v1 spec) gains an optional `tui_scheme:
   emacs | vim | vscode` key. Default is `emacs` to preserve
   GEP-37 behaviour.
4. **Scheme fidelity.** Each built-in scheme should be **close
   to its namesake, not a pixel-perfect emulation.** Vim mode
   provides modal editing with `j/k/h/l` and common `g<letter>`
   prefixes; it does *not* try to replicate every obscure
   `:ex-command`. VS Code mode provides Ctrl-chords and the
   command palette; it does *not* try to match VS Code's
   command registry 1:1. Faithful-enough for the muscle-memory
   test; not a re-implementation.
5. **Help overlay per scheme.** The `?` (or `C-h k` in Emacs
   mode) keys-help overlay renders from the *active* scheme's
   map. There is exactly one keys-help renderer, parameterised
   by scheme.

## Open questions

- **Fidelity bar.** How close is "close enough" for each
  scheme? Example: VS Code's `Ctrl+P` is quick-open, but Glorbo
  has nothing directly analogous — what gets bound there?
  Answering this per-scheme requires a walkthrough with a user
  from each lineage.
- **Composer behaviour in Vim mode.** Vim's modal editing means
  the composer is in insert-mode vs normal-mode. Does the TUI
  actually implement modes, or does Vim mode just provide
  `:`-prefix command entry + `j/k/y/n` on read-only views?
  Leaning toward the latter — mode-ful editing is a big
  complexity add for marginal fidelity.
- **Per-user schemes if/when we add multi-user.** Glorbo is
  single-user-per-instance today. If GEP-39 ships before
  hypothetical multi-user support, does the scheme config
  stay on disk or become a per-user setting? Parking for later.
- **Config reload vs restart.** Config file change mid-session
  — does the TUI reload its keymap, or does the user restart?
  Restart is simpler; reload requires wiring a file watcher on
  config.md. Leaning restart-only.
- **Keys-help overlay content.** One rendering path per
  scheme, but the *actions* list is scheme-independent. Does
  the overlay group by action category (Navigation / Views /
  Approvals / …) or by key-chord layout? Design detail for
  the Draft.
- **Tests.** Each scheme needs a round-trip test (action →
  key-sequence → emitted action matches input) plus a
  fixture-based "typical workflow" E2E. Three schemes × five
  views × handful of workflows = real test surface. Worth
  budgeting before committing to three-scheme scope.
- **Does this extend GEP-37 D10 or supersede it?** Draft-time
  call. Extends, most likely — GEP-37 still documents "ships
  one default," GEP-39 adds alternatives without revising the
  default choice.

## Prerequisites for promotion to Draft

Mechanical:

- GEP-37 has landed and `glorbo tui` ships.
- `Glorbo.Tui.Keybindings` exists as a module the current Emacs
  scheme lives in — that's the hook the new schemes plug into.
- Someone has asked for a non-Emacs scheme. Per user's guidance
  on 2026-04-24: "leave it as placeholder until someone asks
  for implementation."

Design:

- Answer the five open questions above, at least well enough
  to defend a choice in a decision log.
- Enumerate every action the TUI binds. That list becomes
  `Glorbo.Tui.Actions` and it is the contract every scheme
  must implement.

## Related

- **GEP-37** (TUI) — this GEP extends GEP-37's single-scheme
  default by adding configurable alternatives. `requires: [37]`.
- **GEP-19** (Director approval workflow) — web-UI `j/k/y/n`
  shortcuts live here; GEP-39 does not touch them.
- **GEP-30** (TUI Redesign V1 — web aesthetic) — shares the
  IRC-style composer semantics that GEP-39's schemes all
  preserve.
- **GEP-25 / config/v1** — where the `tui_scheme:` key would
  live when the Draft lands.
