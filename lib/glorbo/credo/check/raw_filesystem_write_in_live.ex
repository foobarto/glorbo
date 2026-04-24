defmodule Glorbo.Credo.Check.RawFilesystemWriteInLive do
  @moduledoc """
  GEP-36 ratchet: every filesystem write originating from a LiveView
  handler must go through `Glorbo.Actions.*` so it picks up
  permission + validation + audit-emit in one place.

  The check scans `lib/glorbo_web/live/**/*.ex` for calls to the
  mutating `File.*` functions (`write`, `write!`, `rename`,
  `rename!`, `mkdir_p`, `mkdir_p!`, `rm`, `rm!`, `rm_rf`, `rm_rf!`,
  `cp`, `cp!`, `cp_r`, `cp_r!`, `ln`, `ln_s`, `ln_s!`, `touch`,
  `touch!`, `chmod`) and reports an issue per offending call.

  Already-migrated LiveViews carry no allowlist entry; the check
  fails on the first regression there. LiveViews still awaiting
  migration carry a `:allowlist` entry (below) keyed by their
  relative path, and the check is silent for them so the repo can
  ship GEP-36 in rounds without a flag day.

  As each LiveView is migrated to `Glorbo.Actions.*`, drop its row
  from the allowlist in the check config in `.credo.exs`. When the
  allowlist empties, GEP-36 is done.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowlist: []],
    explanations: [
      check: """
      Raw `File.*` mutations inside LiveView modules must route
      through `Glorbo.Actions.*` instead. The Actions layer owns
      permission checks, input validation, atomic writes, and
      audit emission — all four drift when LiveViews write
      directly.

      The allowlist carries LiveViews still pending migration.
      Shrinking it is the GEP-36 progress bar.
      """
    ]

  @forbidden ~w(
    write write!
    rename rename!
    mkdir_p mkdir_p!
    rm rm! rm_rf rm_rf!
    cp cp! cp_r cp_r!
    ln ln_s ln_s!
    touch touch!
    chmod chmod!
  )a

  @live_prefix "lib/glorbo_web/live/"

  @impl true
  def run(%Credo.SourceFile{} = source_file, params) do
    rel = source_file_rel_path(source_file)

    cond do
      not String.starts_with?(rel, @live_prefix) ->
        []

      rel in Params.get(params, :allowlist, __MODULE__) ->
        []

      true ->
        issue_meta = IssueMeta.for(source_file, params)

        Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp source_file_rel_path(%Credo.SourceFile{filename: filename}) do
    cwd = File.cwd!()

    filename
    |> Path.expand()
    |> Path.relative_to(cwd)
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [:File]}, fun]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when fun in @forbidden do
    {ast, [issue_for(fun, meta[:line] || 0, issue_meta) | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(fun, line, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "raw File.#{fun}/_ in a LiveView — route through Glorbo.Actions.* " <>
          "(GEP-36). If this handler is on the migration queue, add the file " <>
          "to the allowlist in .credo.exs.",
      line_no: line,
      trigger: "File.#{fun}"
    )
  end
end
