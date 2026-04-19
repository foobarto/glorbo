defmodule Mix.Tasks.Glorbo.BuildLocal do
  @moduledoc """
  Build the linux_x86_64 burrito release and (re)link `glorbo` in the
  project root to it.

      mix glorbo.build_local

  Equivalent to:

      MIX_ENV=prod mix release glorbo --overwrite
      ln -sfn burrito_out/glorbo_linux_x86_64 glorbo

  This is the standard "I want to test my latest code via the shipped
  CLI shape" command. The symlink is gitignored (see `.gitignore`);
  every fresh clone starts with no symlink and runs this task to
  materialise one.

  Runs in `:prod` Mix env so the release is ERTS-bundled and
  production-compiled. Subsequent dev work does not need to
  rebuild — the symlink keeps pointing at the same path, and
  re-running this task overwrites in place.
  """
  use Mix.Task

  @shortdoc "Build burrito glorbo + symlink ./glorbo -> burrito_out/glorbo_linux_x86_64"
  @symlink_name "glorbo"
  @target_rel "burrito_out/glorbo_linux_x86_64"

  @impl Mix.Task
  def run(_argv) do
    prev_env = Mix.env()

    try do
      Mix.env(:prod)
      Mix.Task.run("loadconfig")
      Mix.Task.run("release", ["glorbo", "--overwrite"])
    after
      Mix.env(prev_env)
    end

    root = File.cwd!()
    target = Path.join(root, @target_rel)

    if File.exists?(target) do
      link_path = Path.join(root, @symlink_name)
      _ = File.rm(link_path)
      :ok = File.ln_s!(@target_rel, link_path)
      Mix.shell().info("✓ symlinked ./#{@symlink_name} -> #{@target_rel}")
    else
      Mix.shell().error("Expected #{@target_rel} after release build, but it's missing.")
      exit({:shutdown, 1})
    end
  end
end
