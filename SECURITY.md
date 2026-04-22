# Security Policy

Glorbo is a multi-agent orchestration platform where AI agents run inside
`bwrap(1)` sandboxes with kernel-enforced isolation. Because the sandbox is
the trust boundary between untrusted LLM output and the host, we take
sandbox-escape and policy-bypass reports seriously.

> **Status:** Glorbo is pre-1.0 (currently v0.0.x). Security fixes target
> the latest minor only. There are no backports.

## Reporting a Vulnerability

**Preferred:** use GitHub's [private vulnerability reporting][pvr] on this
repository. That opens a confidential Security Advisory, supports CVE
requests, and keeps disclosure coordinated.

**Backup:** email `security@example.invalid` with `[glorbo-security]` in the
subject. PGP key is not yet published — expect plaintext.

Please include:

- Affected version (`glorbo --version` or commit SHA).
- Reproduction steps or a proof-of-concept.
- Impact assessment (what an attacker gains: sandbox escape, cross-company
  access, audit-log tampering, credential disclosure).
- Host kernel, distro, and bwrap version (`bwrap --version`) if relevant
  — userns restrictions vary significantly by distro.

We will acknowledge within **72 hours** and aim to ship a fix within
**90 days**, coordinating public disclosure with you.

[pvr]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

## Supported Versions

| Version | Status                                   |
| ------- | ---------------------------------------- |
| 0.0.x   | Active — security fixes land on `main`.  |
| < 0.0.1 | Unsupported (pre-release development).   |

## Scope — What We Care About Most

The following are **high-severity** by default and warrant immediate triage:

- **Sandbox escape.** Any bypass of the bwrap baseline
  (`--unshare-user-try --unshare-ipc --unshare-pid --unshare-net
  --die-with-parent --cap-drop ALL`) that lets an agent process reach
  host-visible paths, acquire capabilities, or emit network traffic in
  `network: none` mode.
- **Policy-engine bypass.** Agent performs a read/write that violates its
  `agent.md` frontmatter permissions. Per `docs/DESIGN.md`, permissions must be
  enforced at **two** layers (Elixir Router *and* POSIX ACLs inside the
  container) — a break in either layer is a bug, even if the other
  layer would have caught it.
- **Cross-company isolation break.** Any mechanism by which company A
  reads, writes, or observes company B's `~/.glorbo/companies/<B>/`.
- **Audit-log tampering.** `audit/YYYY-MM.jsonl` is append-only by
  invariant. Anything that mutates, deletes, or silently drops entries
  (including log injection that confuses downstream parsers) is in scope.
- **Inbox/outbox directionality violations.** Agent writes to its own
  `inbox/`, another agent's `outbox/`, or reads another agent's `inbox/`
  without Router mediation.
- **Supply-chain tampering.** Flaws in how Glorbo verifies auto-downloaded
  CLI binaries (Claude Code, Gemini CLI, Codex CLI), Ollama models, or
  container images pulled during `glorbo init`. Missing checksums,
  downgrade attacks, TOFU gaps.
- **Credential / secret disclosure.** Any leak of API keys, budget
  tokens, session credentials, or private workspace content via log
  output, error messages, crash dumps, or telemetry.
- **Kernel / OTP crash path** that a non-privileged agent can
  deterministically trigger to take down the whole dashboard or another
  company's agents (crash-isolation invariant from `docs/DESIGN.md`).

## Out of Scope

- **Prompt injection within already-granted permissions.** If an LLM
  decides to use its legitimate `projects:write:foo` capability
  destructively, that is a capability/policy question, not a vulnerability.
  Tighten `agent.md` frontmatter.
- **Bugs in upstream agent CLIs** (Claude Code, Gemini, Codex). Report
  those to their respective projects. If Glorbo's sandboxing fails to
  contain a known upstream bug, that *is* in scope — file it here.
- **Local resource exhaustion / DoS** from a user who already has a
  shell on the Director's machine.
- **Findings in third-party dependencies** that have no exploitation path
  through Glorbo's API surface. Please file upstream; we will still
  track via Dependabot.
- **Social engineering**, phishing of maintainers, or attacks on
  maintainer machines / GitHub accounts.
- **Missing defense-in-depth** that doesn't correspond to a concrete
  exploit (e.g., "you should also add X hardening"). File as a regular
  issue labelled `hardening`.

## Safe Harbor

If you follow this policy in good faith while researching a
vulnerability:

- We will not pursue or support any legal action against you.
- We will work with you to understand and resolve the issue quickly.
- We ask that you avoid privacy violations, destruction of user data,
  and service interruption during your research, and that you give us
  reasonable time to respond before public disclosure.

Research that stays within the bounds above is authorized. Accessing
data that isn't yours, pivoting beyond Glorbo itself, or publishing
details before coordinated disclosure is not.

## Coordinated Disclosure

Default timeline:

- **T+0** — report received.
- **T+3 days** — acknowledgement and initial severity assessment.
- **T+90 days** — public disclosure target (sooner if a fix ships
  earlier; extensions negotiated only with the reporter's agreement).

We request that reporters refrain from public disclosure until a fixed
release is available or the 90-day window has elapsed, whichever comes
first.

## Acknowledgements

Researchers who responsibly disclose valid vulnerabilities will be
credited in the release notes for the fixing version (unless they
request anonymity). There is no monetary bounty program at this time.

---

Questions about this policy? Open a non-sensitive issue or email
`security@example.invalid`.
