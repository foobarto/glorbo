## Pre-existing flaky test (unrelated to Plan 04-03)

- `test/glorbo/sandbox/bwrap_test.exs:271` — "B13: prompt tempfile is
  cleaned up after invocation (no leak)". Passes in isolation (0/15
  failures) but intermittently fails in full-suite concurrent runs due
  to `/tmp/glorbo_bwrap_prompt_*` file-listing race with other Bwrap
  invocations. Observed during Plan 04-03 Task 3 full-suite regression.
  Root cause is `async` test sibling processes creating tempfiles
  during the measurement window. Not caused by Plan 04-03 (zero
  touches to lib/glorbo/sandbox/** in this plan).
