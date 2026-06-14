---
gep: 65
title: Emergency-stop kill switch (`EMERGENCY_STOP.md` sentinel)
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
type: Standards
created: 2026-06-14
requires: [3, 16]
see-also: [19, 36, 46]
history:
  - date: 2026-06-14
    status: Implemented
    note: |
      Retroactive governance GEP. The company-scoped emergency kill switch
      (`lib/glorbo/emergency_stop.ex`, `EmergencyStopMd` FileSpec) shipped
      under the archived T2-C planning with no governing GEP — flagged by
      the 2026-06-14 reconciliation audit as a load-bearing *safety*
      control lacking a design record. This GEP documents the as-built
      semantics; descriptive, not a change.
---

# GEP-65: Emergency-stop kill switch

## Problem

A Director needs a single, unambiguous "stop everything in this company **now**"
control — for a runaway dispatch loop, a budget blowout, or a compromised agent.
This is a safety control: it must be **fail-safe** (its effect survives a BEAM
restart), **scoped** (one company, never the whole machine or another tenant),
and **observable** (every engage/clear is audited). The kill switch shipped with
those properties but no GEP, so the semantics — what gets killed, what the
resulting state is, how the sentinel is authoritative — were undocumented.

## Design — the as-built contract

The switch is a single markdown sentinel file:
`companies/<co>/state/emergency-stop.md` (`Glorbo.FileSpec.EmergencyStopMd`).
**Its presence on disk is the source of truth** — `Glorbo.EmergencyStop` is
stateless between calls; a restart re-reads the sentinel (filesystem-is-truth,
GEP-3). Engaging it does two things:

1. **Stop in-flight (`stop_inflight/1`).** Every currently-running
   `Agent.Server` dispatch for the company is SIGKILLed at the `Task`, and the
   agent's `last_exit_status` is set to `"stopped_by_director"`.
2. **Refuse new dispatch.** `Glorbo.Agent.Dispatch.execute/3` returns
   `{:error, :emergency_stopped}` for the company while the sentinel exists.

The Director clears the stop with `clear/2` (or by removing the file by hand;
dispatch re-enables on the next `engaged?/2` check). Every transition emits an
audit event: `emergency.engage` on engage, `emergency.clear` on clear.

## Decisions

- **D1. Sentinel file is the source of truth, module is stateless.** No ETS /
  GenServer state to lose on restart; the on-disk file is authoritative
  (GEP-3). A crash mid-stop still leaves the company stopped.
- **D2. Company-scoped only.** No global or agent-only granularity in v1 — the
  blast radius is exactly one company, matching the OTP crash-isolation
  boundary (a company's supervision subtree).
- **D3. SIGKILL, not graceful drain.** Emergency stop is for "stop now", so
  in-flight Tasks are hard-killed rather than allowed to finish; the resulting
  `last_exit_status = "stopped_by_director"` records the cause.
- **D4. Audit both transitions.** `emergency.engage` / `emergency.clear` make
  the control auditable like every other Director action (GEP-19/36).

## Failure modes

- **Sentinel removed out-of-band** → dispatch re-enables on the next check
  (the file *is* the state; this is intended, not a bug).
- **Restart while engaged** → the sentinel persists, so dispatch stays refused
  until explicitly cleared.

## Related

- **GEP-3** — sentinel-file-as-truth.
- **GEP-16** — the dispatch pipeline this gate sits in front of.
- **GEP-36** — Director-write/audit discipline (the engage/clear audit rows).
- `lib/glorbo/emergency_stop.ex`, `lib/glorbo/file_spec/emergency_stop_md.ex`.
