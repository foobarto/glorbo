# Per-warning dialyzer suppressions (kept empty by design).
#
# Dialyzer adoption uses a COUNT-based regression gate (see
# docs/testing/dialyzer-baseline.md + the CI dialyzer step), not
# per-warning ignores — the .exs tuple matcher keys on dialyzer's
# absolute file path, which is not portable across CI/local. Add an
# entry here only for a genuinely-unfixable warning, with rationale.
[]
