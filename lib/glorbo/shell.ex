defmodule Glorbo.Shell do
  @moduledoc """
  GEP-37 — `glorbo shell` interactive terminal session for the
  Director.

  Phase 0 (this scaffold): the entry point + CLI wiring exist but
  the actual `term_ui`-driven views are not yet implemented. Calling
  `Glorbo.Shell.run/1` from the CLI prints a placeholder banner and
  exits cleanly. Subsequent phases land the runtime, supervisor,
  views, and event bus per GEP-37 §Design.

  ## Phase boundaries (per GEP-37)

  | Phase | Surface | Status |
  |-------|---------|--------|
  | Phase 0 | CLI wiring + module skeleton + `term_ui` dep | shipped v0.10.0 |
  | Phase 1 | `Glorbo.Shell.{Supervisor, Runtime, EventBus}` | shipped post-v0.12.5 |
  | Phase 2 | First view (Inbox) — drop-in parity with the LV inbox (read-only) | shipped post-v0.12.5 |
  | Phase 2b | Inbox actions: approve (`a`) + deny (`d`) | shipped post-v0.12.5 |
  | Phase 2c | Deny-reason prompt UX + term_ui.runtime.run wire-up | next round |
  | Phase 3 | Remaining views in drop-in parity order | next round |

  ## Why a placeholder

  Wiring the CLI verb without an implementation is intentional:

    * It proves the dispatch path resolves end-to-end.
    * It surfaces in `glorbo --help` so users see the verb is on
      the roadmap (marked `[alpha]` per the rollout plan).
    * It gives the integration test something to assert against
      without requiring a TTY.
    * Subsequent rounds can land Phase 1's runtime + Phase 2's
      first view as additive changes against this skeleton; no
      further CLI dispatch work needed.
  """

  @doc """
  Entry point invoked by `Glorbo.CLI.dispatch(["shell" | _])`.

  Returns `{:shell, exit_code, output}` matching the CLI's tuple
  shape. Phase 0: detects whether stdin is a TTY (per GEP-37
  failure-modes table — refusing non-TTY use), prints the
  placeholder banner, exits 0.
  """
  @spec run([String.t()]) :: {:shell, 0 | 1 | 2, String.t()}
  def run(args) do
    cond do
      "--help" in args or "-h" in args ->
        {:shell, 0, help_text()}

      not interactive_tty?() ->
        {:shell, 1, non_tty_message()}

      true ->
        {:shell, 0, placeholder_banner()}
    end
  end

  # ----------------------------------------------------------------

  defp interactive_tty? do
    # IO.ANSI.enabled?/0 returns true when stdout is attached to a
    # TTY supporting ANSI sequences. Sufficient for Phase 0; Phase
    # 1's runtime will use term_ui's own TTY probe.
    IO.ANSI.enabled?()
  end

  defp placeholder_banner do
    """
    ▚ glorbo shell — interactive Director terminal (alpha)

    Phase 0 scaffold: the CLI verb is wired and the term_ui dependency
    is on the path. Phase 1 (runtime + supervisor + event bus) and
    Phase 2 (first view: Inbox) land in subsequent rounds — see
    docs/geps/0037-glorbo-shell.md for the full roadmap.

    Until then: use `glorbo serve` + the LiveView dashboard at
    http://localhost:4000 for interactive Director work.
    """
  end

  defp non_tty_message do
    """
    glorbo shell — refusing to launch: stdin/stdout is not a TTY.

    The shell needs an interactive terminal session. If you're
    looking for non-interactive use:

      * `glorbo run <agent>`            — one-shot agent dispatch
      * `glorbo history log`            — durable change history
      * `glorbo doctor --json`          — machine-readable health
    """
  end

  defp help_text do
    """
    glorbo shell — interactive Director terminal session (GEP-37).

    USAGE
      glorbo shell                Open the interactive shell.
      glorbo shell --help         Print this help.

    STATUS

      Phase 0 (alpha) — CLI wired, `term_ui` dep installed,
      placeholder banner shown. Runtime + views land in
      subsequent rounds. The LiveView dashboard at
      http://localhost:4000 (via `glorbo serve`) remains the
      primary Director surface.

    SEE ALSO

      docs/geps/0037-glorbo-shell.md — full design + view list.
      glorbo serve --help            — current-shipping dashboard.
    """
  end
end
