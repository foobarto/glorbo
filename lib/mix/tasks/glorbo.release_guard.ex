defmodule Mix.Tasks.Glorbo.ReleaseGuard do
  @moduledoc """
  Aliased target for `mix release` (see `mix.exs` `:aliases`).

  Wraps the underlying `mix release` task with two guard rails:

    * **Always pass `--overwrite`** so a re-build doesn't pause on
      `"Release glorbo-X.Y.Z already exists. Overwrite? [Yn]"`. There
      is no scenario in this project where the answer is no — the
      release artifact is single-use and disposable; the prompt only
      blocks non-interactive CI/scripts.

    * **Refuse if another `mix release` is already running** on the
      same checkout. Burrito 1.5.0 uses a shared `.zig-cache/` and
      writes `payload.foilz.xz` non-atomically; two concurrent runs
      race and the loser fails late with `FileNotFound: payload.foilz.xz`,
      potentially leaving `burrito_out/` half-overwritten.

  Both guards mirror what `mix glorbo.build_local` already does.
  Wrapping `mix release` itself catches direct callers (`mix release`,
  `mix release glorbo`, CI scripts) too.
  """
  use Mix.Task

  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    refuse_if_concurrent_build!()

    argv =
      if "--overwrite" in argv do
        argv
      else
        argv ++ ["--overwrite"]
      end

    Mix.Task.run("release", argv)
  end

  defp refuse_if_concurrent_build! do
    my_pid = "#{System.pid()}"

    case System.cmd("pgrep", ["-af", "mix release"], stderr_to_stdout: true) do
      {output, 0} ->
        others =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.contains?(&1, my_pid))

        unless others == [] do
          Mix.shell().error(
            "refusing concurrent build — another mix release is running:\n  " <>
              Enum.join(others, "\n  ") <>
              "\n(Burrito's payload.foilz.xz race; wait for it to finish or kill it)"
          )

          exit({:shutdown, 1})
        end

      _ ->
        :ok
    end
  end
end
