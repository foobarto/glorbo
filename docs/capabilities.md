# Capability ledger

Current implementation status for operator-visible and security-sensitive
features. GEPs remain the decision record; this page describes what the code
ships today.

| Capability | Status | Canonical boundary | Verification |
|---|---|---|---|
| Company and agent lifecycle | Implemented | `Glorbo.Actions.Companies`, `Glorbo.Actions.Agents`, company supervisors | unit and LiveView tests |
| Task create/edit/assign/archive | Implemented | `Glorbo.Actions.Tasks` | Actions, LiveView, and MCP tests |
| Approval decisions | Implemented | `Glorbo.Actions` plus `Glorbo.Approvals.Gate` | approval and integration tests |
| Channels and messages | Implemented | `Glorbo.Actions.Channels`, `Glorbo.Actions` | Actions and MCP tests |
| Proposals | Implemented | `Glorbo.Actions.Proposals` via agent outboxes | MCP and Router tests |
| Per-dispatch path grants | Implemented | `Glorbo.PathRequestGate`, supervised `Glorbo.PathGrantStore` | lifecycle and sandbox mapping tests |
| Dashboard and MCP mutation parity | Implemented for shipped mutations | `Glorbo.Actions.*` | frontend write-boundary Credo check |
| Browser bootstrap authentication | Implemented | `GlorboWeb.DirectorAuth`, `GlorboWeb.SetupBanner` | auth and one-shot banner tests |
| Native-provider harness | Implemented | `Glorbo.CLI.Harness` | unit and integration tests |
| Terminal shell | Partial | `Glorbo.Shell.*` | bounded subset of dashboard capabilities |
| Ollama integration | Partial | `Glorbo.Ollama.*` | GEP-67 phases 1–3 shipped; phases 4–5 remain open |
| Router decomposition | Partial | `Glorbo.Company.Router` and extracted filesystem/action seams | GEP-35 remains a structural follow-up |

## Contract checks

The high-value executable contracts are:

```bash
mix test
mix test --only integration
mix credo --strict
mix dialyzer
```

Dialyzer is currently governed by a warning-count regression gate documented
in `docs/testing/dialyzer-baseline.md`; it is not yet a zero-warning gate.
