---
gep: 10
title: Agent and Role-Specific Skill Templates
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-17
updated: 2026-04-18
requires: [2]
see-also: [4, 8, 15]
history:
  - date: 2026-04-17
    status: Placeholder
    note: Idea captured with problem statement, goals, non-goals, and open questions. Implementation shape still to be worked out via brainstorm before promoting to Draft.
  - date: 2026-04-18
    status: Draft
    note: Brainstorm resolved the 10 open questions. Scope narrowed to 3 agent templates (CEO, Engineer, Researcher) + 2 skill templates (code-review, web-search) for v1. Decisions recorded as D4–D13.
---

# GEP-10: Agent and Role-Specific Skill Templates

## 1. Problem

Creating a new agent today means writing `agent.md` from scratch:
name, role, reports-to, provider, model, budget, heartbeat, network
policy, skills list, permission declarations, system prompt. Every
field has to be chosen by the Director, even for archetypal roles —
CEO, Engineer, Researcher, Reviewer, Copywriter — that most users
will want variations of.

Two frictions fall out of this:

1. **High cost of getting started.** The first agent is the
   hardest; users don't know what sensible defaults look like. A
   blank `agent.md` is intimidating; a good starting point is
   drastically more approachable.
2. **No canonical patterns.** Every Director invents their own
   phrasing for "CEO system prompt," their own permission
   selections, their own skill lists. The same ideas get
   re-implemented with subtle differences across installations.

Skills (`companies/<slug>/skills/*.md`) have the same issue at their
layer. A "code review" skill looks similar across every installation
that has one, but there's no starter version to reference or scaffold
from.

## 2. Goals

- Provide a **library of starter templates** for common agent roles
  and role-specific skills.
- Scaffold a new agent from a template via `glorbo new agent
  <company> <name> --template <role>`.
- Scaffold a role-appropriate skill bundle via `glorbo new skill
  <company> <name> --template <slug>`.
- Templates are **starting points, not rigid schemas** — the user
  edits `agent.md` after scaffolding; Glorbo doesn't re-render.
- Keep the template library extensible (users can add their own)
  and versionable (so upstream refinements are adoptable without
  overwriting user edits).

## 3. Non-goals

- **Not** enforcing that agents conform to a template after
  creation. Once scaffolded, the agent is a plain `agent.md`; the
  template leaves no runtime trace.
- **Not** a marketplace / plugin system in this GEP. If a community
  skill exchange becomes desirable, it's a separate GEP layering on
  top of this one.
- **Not** creating templates for *every* imaginable role. A small
  curated set is more useful than a kitchen-sink list.
- **Not** parameter-rich generators with interactive Q&A. Templates
  render with a handful of variable substitutions (name, company,
  reports_to) and that's it — keep the scaffolding simple.

## 4. Open questions — resolved 2026-04-18

All ten resolved in brainstorm on 2026-04-18. Resolutions are
recorded as D4–D13 in §9 and summarised below; the original question
text is kept verbatim for historical context.

1. **Where do built-in templates live on disk?** Options:
   `priv/templates/agents/*.md` inside the Glorbo release; a
   separate `glorbo-templates` repo; `~/.glorbo/templates/` on
   disk (bootstrappable from a built-in set on first `glorbo
   init`). Tradeoffs: upgradeability, user-override friction,
   discoverability.
2. **How do users override?** Drop-in files under
   `~/.glorbo/templates/` that shadow built-ins by name? Fork-and-
   modify pattern? Per-company templates under
   `~/.glorbo/companies/<slug>/.templates/`?
3. **Template format.** Same as `agent.md` (markdown + YAML
   frontmatter) with `{{ mustache }}` substitutions? Something
   more structured (a companion `template.yaml` listing required
   variables)? Minimal: treat it as a plain `agent.md` where the
   user does a find-and-replace on placeholders.
4. **Variable set.** What gets substituted at scaffold time?
   `{{ name }}`, `{{ company.name }}`, `{{ company.slug }}`,
   `{{ reports_to }}`, `{{ provider }}`, `{{ model }}`, today's
   date. Keep it small; anything more should be a manual post-
   scaffold edit.
5. **Skill coupling.** Does an agent template reference skill
   templates? E.g. "engineer" template says `skills: [code-review,
   web-search]` — do those skills get auto-scaffolded if missing
   from the company, or is the user expected to scaffold them
   separately?
6. **Role → permission presets.** A CEO template probably wants
   `chat:read:*, chat:write:*, agents:message:*, budget:read:*`;
   an engineer wants narrower. What's the source of truth for
   "CEO default permissions" — the template file itself, or a
   separate registry?
7. **System prompts.** Opinionated prose that survives multiple
   Directors' refinement? Or minimal skeletons the Director always
   expands on? Compromise: opinionated enough to be runnable,
   clearly marked as "edit me."
8. **Versioning.** How does a user adopt template changes from a
   Glorbo upgrade without clobbering their in-place edits? Probably:
   templates don't rewrite in place. Upgrades surface "new or changed
   template X available; diff against the one you scaffolded from:
   <cmd>." User decides.
9. **Curated set.** Which roles are worth shipping? Strong
   candidates: Director (Director is the human, but a `director-
   assistant` template may be useful), CEO, CTO, Engineer,
   Researcher, Reviewer, Copywriter, Analyst. Start small (3–5),
   add based on real requests.
10. **Skill templates curated set.** Web search, code review,
    retrieval, summarisation, translation, code-runner (external
    tool wrapping). Start with 2–3 obvious ones.

## 5. Proposed shape (subject to brainstorm)

### CLI surface

```bash
glorbo new agent acme engineer-alice --template engineer
glorbo new agent acme ceo --template ceo --reports-to director

glorbo new skill acme code-review --template code-review

glorbo templates list           # enumerate available templates
glorbo templates show engineer  # print template contents without scaffolding
```

### Template file shape (strawman)

`priv/templates/agents/engineer.md`:

```markdown
---
name: "{{ name }}"
role: Software Engineer
reports_to: "{{ reports_to }}"
provider: "{{ provider }}"
model: "{{ model }}"
budget:
  monthly_usd: 30.00
  alert_at_pct: 80
heartbeat: "*/30 * * * *"
network: api-only
skills:
  - code-review
  - web-search
permissions:
  - projects:read:*
  - projects:write:{{ default_project }}
  - tasks:create:{{ default_project }}
  - tasks:update:{{ default_project }}
  - agents:list
  - agents:message:{{ reports_to }}
  - chat:write:engineering
  - chat:read:*
  - budget:read:self
---

## System Prompt

You are a Software Engineer at {{ company.name }}. Your mission is
aligned with the company goal: {{ company.mission }}.

You report to {{ reports_to }}. Your domain is [EDIT: specify
technical area]. Prefer correctness over cleverness; ship small
atomic changes; ask clarifying questions rather than guess.

[EDIT: add role-specific guardrails, preferred libraries, banned
patterns, etc.]
```

`priv/templates/skills/code-review.md`:

```markdown
---
name: code-review
description: Structured code review — flag bugs, security issues, style deviations.
tags: [engineering, review]
---

## Purpose

When asked to review code, produce a structured review covering:

1. Correctness — bugs, edge cases, error handling.
2. Security — injection vectors, auth, input validation.
3. Style — consistency with project conventions (if visible).
4. Tests — missing cases, brittle assertions.

[EDIT: add project-specific review priorities.]
```

### Scaffolding behaviour

1. `glorbo new agent <company> <name> --template <role>`:
   - Resolve template from built-in set first, user-override set
     second.
   - Collect required substitution vars (name, reports_to, etc.)
     either from CLI flags or an interactive prompt.
   - Render into `companies/<company>/agents/<name>/agent.md` with
     companion `inbox/`, `outbox/`, `workspace/`, `history/` dirs.
   - Print "scaffolded from template `engineer` v<VERSION>; edit
     `agents/<name>/agent.md` to customise."
2. Glorbo runtime doesn't re-read the template. The scaffolded file
   is the authoritative agent definition from this point on.

### User-provided templates

- Drop a file under `~/.glorbo/templates/agents/my-role.md` or
  `~/.glorbo/templates/skills/my-skill.md`.
- Name shadows built-in if identical.
- `glorbo templates list` shows both built-ins and user entries,
  flagged by source.

## 6. Migration and rollout

- **Templates ship with the release binary** in `priv/templates/`,
  extracted on first `glorbo init` into a read-only reference
  location inside `~/.glorbo/`.
- **Existing agents are untouched.** This GEP is additive;
  scaffolding is opt-in via the `--template` flag.
- **Upgrade path:** a new release with updated templates prints
  "N templates updated since last upgrade; `glorbo templates diff`
  to inspect."

## 7. Failure modes

- **Template referenced doesn't exist.** Error at scaffold time:
  "template `foo` not found; available: [list]."
- **Required variable not provided.** Prompt interactively or error
  with "required: reports_to (—reports-to <name>)."
- **User override has invalid syntax.** Lint at `glorbo templates
  list` time; mark broken entries with a clear error.
- **Scaffolded agent name collides with existing agent.** Refuse to
  overwrite unless `--force` is passed; suggest different name.

## 8. Test strategy

- Snapshot tests for built-in templates (render with fixed vars,
  compare to golden output).
- Integration: `glorbo new agent acme test --template engineer`
  produces the expected directory structure and valid `agent.md`.
- Lint: all built-in templates parse successfully against the
  agent-definition schema.
- User override: place a fake template in a temp `~/.glorbo/
  templates/`, confirm it shadows the built-in.

## 9. Decision log

(Intentionally sparse — this GEP is in early Draft. Decisions will
be filled in during the brainstorm that takes this to Accepted.)

### D1. Templates are starting points, not runtime contracts

- **Decided:** after scaffolding, the template leaves no runtime
  trace. The agent is a plain `agent.md`; Glorbo never re-renders.
- **Alternatives:** keep templates as live schemas (agents inherit
  from them); re-render on template updates.
- **Why:** filesystem-as-source-of-truth (GEP-3) means user edits
  to `agent.md` are authoritative. A live-inherit model would fight
  that — users edit the scaffolded file, template changes, now what?
  Re-render destroys user edits; selective re-render needs a conflict
  UI we don't want to build. Keeping templates "scaffolding only"
  stays honest with the invariant.

### D2. Start with a small curated set, not a kitchen sink

- **Decided:** ship 3–5 agent templates and 2–3 skill templates in
  the first release. Add based on real user requests, not
  speculation.
- **Alternatives:** ship comprehensive library from day one; ship
  nothing and let users write all their own.
- **Why:** small curated set is more maintainable, clearer in docs,
  and provides the highest leverage (covering the common cases).
  Comprehensive library means every template is lightly tested.
  Shipping nothing leaves the friction we're trying to remove.

### D3. Built-in templates ship in the release; user overrides live in `~/.glorbo/`

- **Decided:** built-ins live in `priv/templates/` inside the
  release. Users override by dropping files under `~/.glorbo/
  templates/`.
- **Alternatives:** all templates in `~/.glorbo/` (built-ins copied
  on init); separate `glorbo-templates` Hex package; remote template
  registry.
- **Why:** keeping built-ins in the release means upgrades update
  them predictably without user data touched (GEP-3 invariant).
  `~/.glorbo/templates/` for overrides is symmetric with how the
  provider registry (GEP-8) layers user config on built-ins. A
  remote registry is premature.

### D4. Built-in templates ship under `priv/templates/{agents,skills}/*.md`

- **Decided:** `priv/templates/agents/*.md` + `priv/templates/skills/*.md`
  inside the Glorbo release. Loaded via `Application.app_dir(:glorbo,
  "priv/templates")` (same pattern as provider TOMLs in GEP-8).
- **Alternatives:** separate `glorbo-templates` repo; extract to
  `~/.glorbo/templates/` on `glorbo init`; remote registry.
- **Why:** symmetric with GEP-8 provider layout, no extraction step
  needed, Burrito bundles `priv/` already. Separate repo / remote
  registry are premature for a template library with 5 entries.

### D5. User overrides shadow by filename under `~/.glorbo/templates/`

- **Decided:** a file at `~/.glorbo/templates/agents/<name>.md`
  shadows `priv/templates/agents/<name>.md` by the filename. Skills
  analogously.
- **Alternatives:** per-company template dirs; fork-and-modify
  workflow; no overrides until v2.
- **Why:** single shadow rule is one sentence to explain. Mirrors
  GEP-8's `~/.glorbo/providers.toml` layering of user config onto
  built-ins. Per-company dirs would create a four-way lookup (user
  per-company → user global → builtin per-company → builtin global)
  with no clear benefit.

### D6. Plain markdown + YAML + `{{ var }}` placeholders

- **Decided:** template file IS an `AGENT.md` / skill markdown file
  with `{{ variable }}` placeholders. No companion `template.yaml`
  or declared-variable manifest.
- **Alternatives:** companion YAML file listing required variables;
  EEx; mustache library dependency.
- **Why:** the template shape IS the output shape — `cat
  priv/templates/agents/ceo.md` shows what gets scaffolded. A
  manifest is ceremony for placeholders that are obvious in the
  template body. A hand-rolled `String.replace/3` loop is ~10 lines
  of Elixir; a mustache dep is overkill.

### D7. Fixed 8-variable set, no escape hatch

- **Decided:** variables available to every template:
  - `{{ name }}` — agent display name (defaults to slug upcased)
  - `{{ slug }}` — agent slug (lowercase, `[a-z][a-z0-9_-]{0,63}`)
  - `{{ company }}` — company slug
  - `{{ company_upper }}` — company slug uppercased for display
  - `{{ reports_to }}` — reports-to target (default `director`)
  - `{{ provider }}` — provider name (default `claude-code`)
  - `{{ model }}` — model id (default `claude-sonnet-4-5`)
  - `{{ date }}` — YYYY-MM-DD scaffold date
- **Alternatives:** project-specific vars like `{{ default_project }}`;
  template-declared extension vars; full EEx.
- **Why:** every extra variable creates a required-argument failure
  mode. The Director can hand-edit after scaffold. If a template
  needs project-specific content, the Director writes the project
  slug in themselves — it's a one-line edit.

### D8. Templates carry skill dependencies but scaffolder does NOT auto-create skills

- **Decided:** agent template frontmatter can include
  `skills: [code-review]`; scaffolding an agent with a missing
  company-level skill emits a warning line with the remediation
  command (`glorbo new skill acme code-review --template code-review`).
- **Alternatives:** auto-scaffold missing skills; refuse to scaffold
  if skills are missing; ignore the dependency entirely.
- **Why:** auto-scaffolding means one command has side effects in
  adjacent directories — surprising. Refusing blocks the common
  "I know what I'm doing" path. A warning is enough nudge without
  being obstructive.

### D9. Permissions live in the template frontmatter

- **Decided:** role-appropriate permissions are declared directly
  in the template's frontmatter. No separate permission registry.
- **Alternatives:** `priv/templates/permissions.toml` mapping role →
  permission list; inherited from a base template.
- **Why:** single source of truth per template. Director can read
  `priv/templates/agents/ceo.md` to see exactly what the CEO gets.
  A separate registry creates two files to keep in sync, and role
  inheritance is a feature we don't have a use case for.

### D10. Opinionated system prompts with `[EDIT: ...]` markers

- **Decided:** each template ships an opinionated but short system
  prompt with `[EDIT: ...]` markers on the parts that must be
  customised per installation.
- **Alternatives:** blank system prompts; elaborate "director's
  guide to system prompts" in docs.
- **Why:** a blank prompt defeats the purpose of the template
  library. A too-prescriptive one becomes the Glorbo default voice
  for every CEO on earth, which is cringe. `[EDIT: ...]` markers
  are a visible nudge that this is a starting point, not a contract.

### D11. No versioning story in v1

- **Decided:** v1 ships with no template-versioning mechanism.
  Glorbo upgrades that refine templates are documented in
  CHANGELOG and the Director can re-scaffold into a sibling
  directory to diff by hand.
- **Alternatives:** semver per template; `glorbo templates diff`;
  "template updated since last upgrade" nag screens.
- **Why:** per D1, templates leave no runtime trace after scaffold.
  The in-place `AGENT.md` is authoritative forever. Which version
  of the template it came from is archaeology — git log of the
  scaffold commit answers it.

### D12. Curated agent template set: CEO, Engineer, Researcher

- **Decided:** v1 ships exactly three agent templates:
  **CEO**, **Engineer**, **Researcher**. More get added when real
  user requests surface patterns we missed.
- **Alternatives:** kitchen sink (CEO, CTO, Engineer, QA, PM,
  Researcher, Reviewer, Copywriter, Analyst, Designer, ...);
  zero templates (users always start from blank).
- **Why:** these three cover the 80% archetype split —
  executive/strategic, technical/implementation, and
  investigative/information-gathering. Every additional template
  needs ongoing curation and risks becoming stale vocabulary. Four
  isn't meaningfully better than three for the first release.

### D13. Curated skill template set: code-review, web-search

- **Decided:** v1 ships exactly two skill templates: **code-review**
  and **web-search**. Both are concrete, have well-understood shapes,
  and compose with multiple agent templates.
- **Alternatives:** ship "retrieval", "summarisation", "translation",
  "code-runner" too; ship zero skills.
- **Why:** concrete over meta. `code-review` is used by Engineer
  templates; `web-search` is used by Researcher. "Retrieval" and
  "summarisation" are meta-capabilities whose templates would end
  up too abstract to be useful without heavy context.

## 10. Related

- **GEP-2** — architecture overview (templates are a new capability
  layered on top of existing agent definitions).
- **GEP-4** — CLI-tool agents (templates preset `provider` and
  `model` fields that GEP-4 defines).
- **GEP-3** — filesystem as source of truth (D1 above depends on
  this invariant).
- `DESIGN.md` §5.1 (agent definition format) — templates render into
  this format.
