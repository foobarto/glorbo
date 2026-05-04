defmodule Glorbo.CLI.ServeTest do
  @moduledoc """
  Plan 05-02 Task 1 — `Glorbo.CLI.Lifecycle.Serve`.

  `serve` blocks on `Process.sleep(:infinity)` in production; the
  `--exit-after` test-only switch replaces the block with a bounded
  sleep so ExUnit can assert the return shape without spawning a
  parallel Task.

  The full-tree start path is tagged `:integration` because it starts
  the Phoenix endpoint + full supervision tree, which conflicts with
  the LiveViewTest + ConnCase setup used by most tests in this suite.
  """
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Lifecycle.Serve

  describe "serve" do
    test "--help returns help text" do
      assert {:serve, 0, out} = Serve.run(["--help"])
      assert out =~ "glorbo serve"
      assert out =~ "USAGE"
      assert out =~ "--exit-after"
    end

    @tag :integration
    test "--exit-after returns within the given window", %{glorbo_home: _home} do
      # 200ms is enough to start the tree + unblock.
      start = System.monotonic_time(:millisecond)
      assert {:serve, 0, out} = Serve.run(["--exit-after", "200"])
      elapsed = System.monotonic_time(:millisecond) - start

      assert out =~ "glorbo serve exited"
      assert out =~ "200ms"
      # Generous upper bound (supervision tree start can take time).
      assert elapsed < 10_000, "serve took #{elapsed}ms — tree start blocked too long?"
    end

    test "enable_endpoint_serving flips :server to true when flag is on" do
      # Regression: in a Burrito release, runtime.exs only sets `server: true`
      # when PHX_SERVER is set; without this auto-enable, `glorbo serve`
      # printed the banner but port 4000 never bound.
      prev_flag = Application.get_env(:glorbo, :serve_starts_endpoint, true)
      prev_endpoint = Application.get_env(:glorbo, GlorboWeb.Endpoint, [])

      try do
        Application.put_env(:glorbo, :serve_starts_endpoint, true)

        Application.put_env(
          :glorbo,
          GlorboWeb.Endpoint,
          Keyword.put(prev_endpoint, :server, false)
        )

        assert :ok = Serve.enable_endpoint_serving()

        cfg = Application.get_env(:glorbo, GlorboWeb.Endpoint)
        assert Keyword.get(cfg, :server) == true
      after
        Application.put_env(:glorbo, :serve_starts_endpoint, prev_flag)
        Application.put_env(:glorbo, GlorboWeb.Endpoint, prev_endpoint)
      end
    end

    test "enable_endpoint_serving is a no-op when flag is off (test default)" do
      prev_flag = Application.get_env(:glorbo, :serve_starts_endpoint, true)
      prev_endpoint = Application.get_env(:glorbo, GlorboWeb.Endpoint, [])

      try do
        Application.put_env(:glorbo, :serve_starts_endpoint, false)

        Application.put_env(
          :glorbo,
          GlorboWeb.Endpoint,
          Keyword.put(prev_endpoint, :server, false)
        )

        assert :ok = Serve.enable_endpoint_serving()

        cfg = Application.get_env(:glorbo, GlorboWeb.Endpoint)
        assert Keyword.get(cfg, :server) == false
      after
        Application.put_env(:glorbo, :serve_starts_endpoint, prev_flag)
        Application.put_env(:glorbo, GlorboWeb.Endpoint, prev_endpoint)
      end
    end
  end
end
