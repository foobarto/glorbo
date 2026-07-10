defmodule Glorbo.Integration.UpDownStatusTest do
  @moduledoc """
  Plan 05-02 integration — live Burrito subprocess lifecycle.

  Tagged `:integration` (excluded from default suite). Skips gracefully
  when the compiled burrito binary is not present (CI builds it first;
  dev can run `mix release --overwrite` to materialise it).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  @default_burrito_bin "_build/prod/rel/glorbo/glorbo"

  describe "up → status → down → status subprocess round-trip" do
    test "full lifecycle against a real burrito binary" do
      bin =
        System.get_env("GLORBO_INTEGRATION_BIN", @default_burrito_bin)
        |> Path.expand(File.cwd!())

      if File.exists?(bin) do
        run_live(bin)
      else
        IO.puts(
          :stderr,
          "skipping up_down_status integration — no burrito binary at #{bin} " <>
            "(run `mix release --overwrite` to build)"
        )

        :ok
      end
    end
  end

  defp run_live(bin) do
    home =
      Path.join(
        System.tmp_dir!(),
        "glorbo-integration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)

    on_exit(fn ->
      # Best-effort SIGKILL in case the test bailed mid-way.
      case File.read(Path.join([home, "run", "glorbo.pid"])) do
        {:ok, content} ->
          case Integer.parse(String.trim(content)) do
            {pid, _} ->
              _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

            _ ->
              :ok
          end

        _ ->
          :ok
      end

      File.rm_rf!(home)
    end)

    env = [{"GLORBO_HOME", home}]

    # 1. `glorbo up`
    {up_out, 0} = System.cmd(bin, ["up"], env: env)
    assert up_out =~ "pid="

    # 2. Poll `glorbo status` up to 30s for port to bind.
    assert eventually_running?(bin, env, 300),
           "status never reported running + port 4000 listening within 30s"

    # 3. `glorbo down` — exit 0.
    {down_out, 0} = System.cmd(bin, ["down"], env: env)
    assert down_out =~ "glorbo stopped"

    # 4. Final status — exit 3 (not running).
    {_status_out, status_code} = System.cmd(bin, ["status"], env: env)
    assert status_code == 3
  end

  # Poll up to `max_iters` * 100ms for status exit 0.
  defp eventually_running?(_bin, _env, 0), do: false

  defp eventually_running?(bin, env, iters) do
    case System.cmd(bin, ["status"], env: env) do
      {_, 0} ->
        true

      _ ->
        Process.sleep(100)
        eventually_running?(bin, env, iters - 1)
    end
  end
end
