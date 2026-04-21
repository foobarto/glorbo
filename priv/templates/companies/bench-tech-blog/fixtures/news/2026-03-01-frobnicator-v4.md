---
source: invented
date: 2026-03-01
topic: frobnicator-v4
---

# Frobnicator v4 released with async routing

**Acme Software** released Frobnicator 4.0.0 on March 1st, 2026.
Headline changes:

- Async task routing moves from a polling loop to a reactor pattern.
  Claimed 3x throughput on the reference benchmark (`bench-12`).
- New `--strict-mode` flag: dispatch refuses ambiguous input instead
  of falling back to best-effort parsing.
- Sunsets the `v2` config format; migration tool ships in-box.

Community reception (as captured on the project forum between Mar 1
and Mar 3): performance wins confirmed on one small workload,
disputed on a different benchmark. Two reports of `--strict-mode`
rejecting input the migration tool emitted — acknowledged as a
known bug targeted for v4.0.1.

**Not in the archive:** numbers for benchmark `bench-17` (cited by
the blog post but the raw data was not published with the release).
