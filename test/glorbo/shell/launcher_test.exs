defmodule Glorbo.Shell.LauncherTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Launcher
  alias Glorbo.Test.TmpGlorboHome

  describe "parse_argv/1" do
    test "single company slug → {:ok, slug}" do
      assert Launcher.parse_argv(["acme"]) == {:ok, "acme"}
    end

    test "ignores trailing extra args (Phase 3 will widen surface)" do
      assert Launcher.parse_argv(["acme", "--theme=dark"]) == {:ok, "acme"}
    end

    test "empty argv → {:error, :usage}" do
      assert Launcher.parse_argv([]) == {:error, :usage}
    end

    test "non-slug input rejected" do
      assert Launcher.parse_argv(["../etc"]) == {:error, {:invalid_slug, "../etc"}}
      assert Launcher.parse_argv(["Acme"]) == {:error, {:invalid_slug, "Acme"}}
      assert Launcher.parse_argv(["acme/bad"]) == {:error, {:invalid_slug, "acme/bad"}}
    end
  end

  describe "validate_company_dir/2" do
    test "existing dir → :ok" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join([base, "companies", "acme"]))
      assert Launcher.validate_company_dir(base, "acme") == :ok
    end

    test "missing dir → {:error, :unknown_company}" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join([base, "companies"]))
      assert Launcher.validate_company_dir(base, "ghost") == {:error, :unknown_company}
    end
  end

  describe "build_runner_opts/2" do
    test "returns root + opts for the Inbox view" do
      opts = Launcher.build_runner_opts("/tmp/glorbo-base", "acme")
      assert Keyword.fetch!(opts, :root) == Glorbo.Shell.Views.Inbox
      view_opts = Keyword.fetch!(opts, :opts)
      assert Keyword.fetch!(view_opts, :base) == "/tmp/glorbo-base"
      assert Keyword.fetch!(view_opts, :company) == "acme"
    end
  end

  describe "run/2" do
    test "happy path invokes runner_fn with composed opts and returns {:ok, 0, _}" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join([base, "companies", "acme"]))

      ref = make_ref()
      Process.put({:runner_called, ref}, nil)

      runner_fn = fn opts ->
        Process.put({:runner_called, ref}, opts)
        :ok
      end

      assert {:ok, 0, ""} = Launcher.run(["acme"], base: base, runner_fn: runner_fn)

      runner_opts = Process.get({:runner_called, ref})
      assert Keyword.fetch!(runner_opts, :root) == Glorbo.Shell.Views.Inbox
      view_opts = Keyword.fetch!(runner_opts, :opts)
      assert Keyword.fetch!(view_opts, :company) == "acme"
      assert Keyword.fetch!(view_opts, :base) == base
    end

    test "missing company argv → {:error, :usage}, runner not invoked" do
      base = TmpGlorboHome.setup()
      ref = make_ref()
      Process.put({:runner_called, ref}, nil)

      runner_fn = fn _opts ->
        Process.put({:runner_called, ref}, :invoked)
        :ok
      end

      assert {:error, :usage} = Launcher.run([], base: base, runner_fn: runner_fn)
      assert Process.get({:runner_called, ref}) == nil
    end

    test "non-existent company dir → {:error, :unknown_company}, runner not invoked" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join([base, "companies"]))
      ref = make_ref()
      Process.put({:runner_called, ref}, nil)

      runner_fn = fn _opts ->
        Process.put({:runner_called, ref}, :invoked)
        :ok
      end

      assert {:error, :unknown_company} =
               Launcher.run(["ghost"], base: base, runner_fn: runner_fn)

      assert Process.get({:runner_called, ref}) == nil
    end

    test "non-slug argv → {:error, {:invalid_slug, _}}, runner not invoked" do
      base = TmpGlorboHome.setup()
      ref = make_ref()
      Process.put({:runner_called, ref}, nil)

      runner_fn = fn _opts ->
        Process.put({:runner_called, ref}, :invoked)
        :ok
      end

      assert {:error, {:invalid_slug, "../etc"}} =
               Launcher.run(["../etc"], base: base, runner_fn: runner_fn)

      assert Process.get({:runner_called, ref}) == nil
    end
  end
end
