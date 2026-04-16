---
gep: 11
title: The Zen of Glorbo
author: Glorbo Maintainers <security@example.invalid>
status: Accepted
type: Informational
created: 2026-04-17
see-also: [2]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial draft modelled after PEP-20. Distilled from the invariants in GEPs 2–9; intended as a tiebreaker when future design choices line up with these principles or against them.
  - date: 2026-04-17
    status: Accepted
    note: Accepted as operational guidance — when a design question arises, reach for the aphorism that applies.
---

# GEP-11: The Zen of Glorbo

*With thanks to [Tim Peters](https://peps.python.org/pep-0020/).
The fleeb juice has always been included.*

A handful of principles for deciding between two shapes. Each line
should help a reviewer answer "which of these options is more
Glorbo-shaped?" If a line doesn't pass that test, it's out.

---

The filesystem is the source of truth; the database is a mirror.

If it cannot be rebuilt from disk, it does not belong in the DB.
*Every blamf in SQLite owes its existence to a blamf on the filesystem.*

A directory is a platform. One binary, one directory, one decision.

The kernel is the policy engine.
*The grumbo is Elixir. The policy is Linux.* Application checks are
belt-and-braces, not the belt.

Prefer the mount that isn't there over the mount you guard.
*A hizzard that doesn't exist in the sandbox can't be unschleemed.*

Wrap the tool that already exists before you write one. Somebody
else's plumbus will do the job.

Prefer a subprocess to a library. Prefer a library to a protocol.
Prefer a protocol to a framework.

A short-lived process with clear inputs beats a long-lived one with
accumulated state. State is ploobis you'll have to clean up later.

Supervise, don't rescue. Crash the process you don't trust; restart
the one you do. *That's OTP, baby.*

Make the correct thing the default; make the incorrect thing
impossible, or failing that, audible.

Inbox in, outbox out. Anything else is bypassing the Router.
*The schlami is there for a reason.*

Append-only is not a restriction; it is a guarantee. Spend it.

Tokens are money. Count them, report them, cap them. *A fleeb without
a budget is a fleeb that will run until it schleems the chumble.*

If a decision needs more than a paragraph to justify, write a GEP.

If a decision needs less than a sentence, don't write a GEP.

Two of us agreeing in Discord is not a decision. A file in
`docs/geps/` is.

Readers land on files, not on tribal knowledge. Write for the
dinglebop who starts tomorrow.

Every configuration knob is a future support request. Add them with
care. *Every fleeb juice flavour is a ticket you haven't opened yet.*

Reindex is not disaster recovery; it is the test that the invariant
still holds. Run it. Break it. Fix what breaks.

Simple boring tools age better than sophisticated novel ones. Glorbo
is sophisticated enough; the tools should be boring. *SQLite is a
perfectly acceptable grumbo.*

The right time to add the abstraction is the second time you need
it, not the first. The third time, you're schleeming for ghosts.

Prefer removing code to refactoring it. Prefer refactoring it to
adding a flag. Prefer adding a flag to adding a feature. Prefer
adding a feature to adding a subsystem.

A permission not declared is not a permission held.

A company cannot see another company. Not by accident, not by bug,
not by design mistake. That is the product. *Every chumble has its
own container. None of them touch.*

When a design becomes contested, a GEP with alternatives documented
ends the argument. Future readers are grateful. Past you is
grateful. *The dinglebop does not remember; the GEP does.*

Archaeology is best served with git, not a parallel tree of stale
docs. If you need the old shape, check out the old tag.
*The chumble that shipped is in the commit. Don't keep a ploobis
museum.*

## Using this document

- **Design reviews.** Cite a line by paraphrase when rejecting or
  approving an approach. ("This adds a long-lived process to hold
  state that could live on disk — prefer short-lived with clear
  inputs.")
- **GEP authoring.** When a decision-log entry's "Why" is struggling
  for words, the Zen often provides them.
- **Disagreement.** A Zen line loses to a GEP with a decision log.
  If a GEP's decision contradicts the Zen, the GEP wins — but the
  contradiction should be acknowledged explicitly in the decision
  log.

These are not rules. They are tiebreakers. When two designs look
close, the one that reads more naturally against this list is
probably more Glorbo-shaped.

## Decision log

### D1. Small, fixed, and operationally useful

- **Decided:** this GEP is a short list of aphorisms that pass the
  "does it help decide between two designs" test. Content is fixed
  after acceptance; growth requires a new GEP that supersedes this
  one.
- **Alternatives:** a living list that any contributor can amend;
  a longer comprehensive style guide; keep it in CLAUDE.md as a
  running note.
- **Why:** PEP-20's power comes from its brevity. A sprawling list
  loses citability. A living list loses authority. Fixing the
  document makes it usable as a rhetorical tool in reviews — "the
  Zen says X" has teeth when X is hard to revise.

### D2. Tiebreaker, not rule

- **Decided:** these lines are explicitly not binding. A GEP with
  a reasoned decision log overrides any Zen aphorism.
- **Alternatives:** treat the Zen as normative; enforce via
  linting / CI; omit the precedence clause and let readers guess.
- **Why:** PEP-20 is not normative for CPython core decisions; it
  is a shared vocabulary for discussing them. Glorbo borrows the
  same model. Making the Zen overridable keeps it honest — the
  rules that should be binding live in GEP-2 (architectural
  pillars) and DESIGN.md (load-bearing invariants).

### D3. Keep the Glorbo voice alongside the operational line

- **Decided:** each aphorism that benefits from it gets a second
  sentence or sentence-fragment in the Glorbo vocabulary (grumbo,
  fleeb, schleem, hizzard, dinglebop, blamf, chumble, ploobis,
  plumbus, schlami). The operational line comes first and carries
  the meaning; the voice line follows and adds flavour.
- **Alternatives:** keep the Zen strictly operational and neutral;
  go full voice and drop the operational framing; scatter the
  voice inconsistently.
- **Why:** the operational line must stand alone — a reviewer
  citing the Zen shouldn't need to translate from Glorbo-speak
  to make the point. But Glorbo's DESIGN.md and README.md commit
  to the voice; stripping it from the Zen would leave this
  document tonally out of step with the project. The two-sentence
  shape (principle, then flavour) keeps both audiences happy:
  reviewers get a clean citation, long-time readers get the voice
  that makes the project feel like itself.

## Related

- [PEP-20: The Zen of Python](https://peps.python.org/pep-0020/) —
  the direct inspiration.
- **GEP-2** — architectural overview; most of these aphorisms are
  distilled from the pillars and decision log there.
- **GEP-3** (filesystem as truth), **GEP-4** (CLI-wrapping),
  **GEP-5** (bwrap sandboxing), **GEP-7** (SQLite derived data) —
  the specific invariants that several lines draw from.
- `DESIGN.md` §1 Philosophy — the prose version of this poetry.
