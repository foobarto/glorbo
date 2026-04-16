defmodule Glorbo.CLI.ServeTest do
  @moduledoc """
  Stubs — filled in by Plan 02.

  `serve` is a blocking verb so the real test runs it inside a
  `Task.async` with a timeout; this skeleton only asserts the tuple
  shape on an early-return path (e.g. --help).
  """
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "serve" do
    test "blocking supervision-tree start + graceful SIGINT" do
      flunk("TODO(plan-02): implement serve under Task.async")
    end
  end
end
