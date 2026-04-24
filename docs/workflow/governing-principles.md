# Governing principles

> Adapted from [Andrej Karpathy's guidelines](https://karpathy.bearblog.dev/dev/)
> for sharper collaboration with LLM coding agents. These override the
> "move fast" impulse. They govern not just code changes but any
> working decision — proposal drafting, design pushback, session
> logging, autonomous rounds.

These four principles are the backbone of the cairn workflow.
Every other artefact (session journals, punch lists, skills,
proposals) is a shape that makes following them easier. When the
shapes conflict with the principles, the principles win.

## 1. Think before coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing (or proposing, or deciding):

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick
  silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

Generalises beyond code: applies to proposal framing, task
picking in autonomous rounds, interpreting user direction,
architectural decisions. When there are multiple reasonable
readings of a situation, make them visible.

## 2. Simplicity first

**Minimum that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

The test: *Would a senior engineer (or architect, or user) say
this is overcomplicated?* If yes, simplify.

Generalises beyond code: proposals shouldn't invent scope that
wasn't requested. Session journals shouldn't be formulaic where
plain prose would do. Skills shouldn't require ceremony where a
one-line instruction suffices.

## 3. Surgical changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code / docs / structure:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete
  it.

When your changes create orphans:

- Remove imports / variables / functions that *your changes*
  made unused.
- Don't remove pre-existing dead code unless asked.

The test: **every changed line should trace directly to the
user's request.**

Generalises beyond code: don't reorganise docs while "just
fixing a typo." Don't rewrite a session-journal entry while
appending a new one. Don't refactor a proposal's decision log
while extending its open questions.

## 4. Goal-driven execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → *Write tests for invalid inputs, then make
  them pass.*
- "Fix the bug" → *Write a test that reproduces it, then make
  it pass.*
- "Refactor X" → *Ensure tests pass before and after.*

For multi-step tasks, state a brief plan:

```
1. [step] → verify: [check]
2. [step] → verify: [check]
3. [step] → verify: [check]
```

Strong success criteria let you loop independently. Weak
criteria ("make it work") require constant clarification.

Generalises beyond code: autonomous rounds need a stop condition
before starting. Proposals need a "done when" clause. Reviews
need explicit accept criteria (quality + security both cleared).

---

## How these principles interweave with the six phases

The [six-phase checklist](six-phase-checklist.md) is *when* —
the rhythm of work, Spec → Ship. These four principles are
*how within each phase*. Every phase leans on some of them
more than others:

| Phase        | Principles most load-bearing in this phase                         |
|--------------|--------------------------------------------------------------------|
| 1. Spec      | **1. Think** — alternatives surfaced, assumptions named. **2. Simplicity** — non-goals kept tight; scope bounded. |
| 2. Plan      | **4. Goal-driven** — verifiable success criteria declared *before* code changes. |
| 3. Build     | **3. Surgical** — every changed line traces to the request. **2. Simplicity** — minimum that solves the problem. |
| 4. Test      | **4. Goal-driven** — tests are the verifiable criteria from phase 2 made concrete. |
| 5. Review    | **1. Think** (reflective) — surface what you assumed during Build. **3. Surgical** — self-review catches scope creep. |
| 6. Ship      | **3. Surgical** — doc pass updates what the change affected, no more. |

If a phase feels wrong during execution, check which principle
it's meant to lean on and ask whether you're actually
following it. The phases are easy to tick off mechanically;
the principles are what make them mean something.

## How these principles integrate with cairn's artefacts

| Artefact              | Principles most load-bearing there                                  |
|-----------------------|---------------------------------------------------------------------|
| Session journal       | **1** (*think*) — *Design calls I made without you* surfaces assumptions. **3** (*surgical*) — honest about what didn't change. |
| Proposal / ep-kit EP  | **1** (*think*) — alternatives in decision log. **2** (*simplicity*) — non-goals kept tight. |
| Rolling punch list    | **2** (*simplicity*) — items stay bounded; no "refactor everything" bullets. |
| Autonomous round/loop | **4** (*goals*) — stop conditions up-front. **3** (*surgical*) — don't scope-creep the bounded task. |
| Review phase          | **4** (*goals*) — explicit quality + security accept criteria. |
| User / project profile | **1** (*think*) — observations with evidence, not judgments. |

---

## Success signal

These principles are working if:

- Fewer unnecessary changes in diffs.
- Fewer rewrites due to overcomplication.
- Clarifying questions come *before* implementation rather than
  after mistakes.
- Autonomous rounds leave coherent trails; loops don't drift
  into scope creep.
- Reviews catch real issues without noise.

If the opposite is happening, the principles aren't being
followed — re-read them before the next task.
