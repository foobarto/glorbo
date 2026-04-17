defmodule Glorbo.CLI.RegistryTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Registry
  alias Glorbo.CLI.Registry.Provider

  setup do
    tmp = Path.join(System.tmp_dir!(), "registry-test-#{System.unique_integer([:positive])}")
    builtin_dir = Path.join(tmp, "builtin")
    File.mkdir_p!(builtin_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{builtin_dir: builtin_dir}
  end

  defp unique_name(prefix) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp write!(dir, name, body), do: File.write!(Path.join(dir, name), body)

  defp minimal(name) do
    """
    name   = "#{name}"
    binary = "echo"
    args   = []
    reply_dir               = "x"
    reply_filename_template = "y"
    """
  end

  describe "boot" do
    test "loads + detects on start_link", %{builtin_dir: dir} do
      write!(dir, "a.toml", minimal("alpha"))

      name = unique_name(:reg)
      start_supervised!({Registry, name: name, builtin_dir: dir, user_file: nil})

      # echo is on PATH on every CI runner we support
      [p] = Registry.list(name)
      assert p.name == "alpha"
      assert p.installed? == true
      assert is_binary(p.resolved_path)
      # no version probes at boot (D3)
      assert p.version == nil
    end

    test "empty builtin dir is allowed" do
      name = unique_name(:reg_empty)
      start_supervised!({Registry, name: name, builtin_dir: "/nonexistent", user_file: nil})
      assert Registry.list(name) == []
    end

    test "load-validation failure crashes boot", %{builtin_dir: dir} do
      write!(dir, "a.toml", minimal("dup"))
      write!(dir, "b.toml", minimal("dup"))

      Process.flag(:trap_exit, true)
      name = unique_name(:reg_dup)

      assert {:error, {%ArgumentError{message: msg}, _stack}} =
               Registry.start_link(name: name, builtin_dir: dir, user_file: nil)

      assert msg =~ "duplicate provider"
    end
  end

  describe "get/2" do
    test "returns the provider by name", %{builtin_dir: dir} do
      write!(dir, "a.toml", minimal("alpha"))

      name = unique_name(:reg_get)
      start_supervised!({Registry, name: name, builtin_dir: dir, user_file: nil})

      assert %Provider{name: "alpha"} = Registry.get("alpha", name)
      assert Registry.get("missing", name) == nil
    end
  end

  describe "refresh/1" do
    test "picks up new files without version probes", %{builtin_dir: dir} do
      write!(dir, "a.toml", minimal("alpha"))

      name = unique_name(:reg_refresh)
      start_supervised!({Registry, name: name, builtin_dir: dir, user_file: nil})

      assert length(Registry.list(name)) == 1

      write!(dir, "b.toml", minimal("beta"))
      Registry.refresh(name: name, builtin_dir: dir, user_file: nil)

      names = Registry.list(name) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["alpha", "beta"]

      # No probing happened
      assert Enum.all?(Registry.list(name), &(&1.version == nil))
    end
  end

  describe "refresh_with_version_probe/1" do
    test "runs probes for opted-in providers", %{builtin_dir: dir} do
      write!(dir, "a.toml", """
      #{minimal("probed")}
      version_flag  = "--version"
      version_regex = '(\\d+\\.\\d+\\.\\d+)'
      """)

      name = unique_name(:reg_probe)
      start_supervised!({Registry, name: name, builtin_dir: dir, user_file: nil})

      cmd_fun = fn _path, _args, _opts -> {"v2.4.8\n", 0} end

      Registry.refresh_with_version_probe(
        name: name,
        builtin_dir: dir,
        user_file: nil,
        system_cmd_fun: cmd_fun
      )

      [p] = Registry.list(name)
      assert p.version == "2.4.8"
    end
  end
end
