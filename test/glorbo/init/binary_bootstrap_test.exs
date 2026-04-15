defmodule Glorbo.Init.BinaryBootstrapTest do
  use ExUnit.Case, async: false

  alias Glorbo.Init.BinaryBootstrap

  @moduletag :binary_bootstrap

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "glorbo_bootstrap_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)
    {:ok, tmp_root: tmp_root}
  end

  describe "ensure_podman/1 — system-first (D-04)" do
    test "returns {:ok, :system, path} when podman is in PATH and never populates ~/.glorbo/bin/",
         %{tmp_root: tmp_root} do
      base = Path.join(tmp_root, "glorbo_home")
      bin_dir = Path.join(base, "bin")

      result =
        BinaryBootstrap.ensure_podman(
          which_fun: fn _ -> "/usr/bin/podman" end,
          base: base
        )

      assert {:ok, :system, "/usr/bin/podman"} = result
      # bin_dir is only created when we fall through to download.
      refute File.exists?(bin_dir),
             "~/.glorbo/bin/ must not be created when system podman is present"
    end

    test "ensure_ollama/1 has the same system-first behaviour", %{tmp_root: tmp_root} do
      base = Path.join(tmp_root, "glorbo_home")

      result =
        BinaryBootstrap.ensure_ollama(
          which_fun: fn name ->
            if name == "ollama", do: "/usr/local/bin/ollama", else: nil
          end,
          base: base
        )

      assert {:ok, :system, "/usr/local/bin/ollama"} = result
    end
  end

  describe "ensure_podman/1 — download path with verified SHA (happy path)" do
    test "downloads, verifies, extracts through staging, and installs podman binary",
         %{tmp_root: tmp_root} do
      base = Path.join(tmp_root, "glorbo_home")
      {fixture_tar, fixture_sha} = build_podman_fixture_tar(tmp_root)

      download_fun = fn _url, dest ->
        File.cp!(fixture_tar, dest)
        {:ok, dest}
      end

      result =
        BinaryBootstrap.ensure_podman(
          which_fun: fn _ -> nil end,
          base: base,
          arch: :amd64,
          expected_sha: fixture_sha,
          download_fun: download_fun
        )

      assert {:ok, :downloaded, installed_path} = result
      assert installed_path == Path.join([base, "bin", "podman"])
      assert File.exists?(installed_path)
      assert File.read!(installed_path) =~ "fake podman"

      # Accessory binaries from the podman-static archive also get copied.
      assert File.exists?(Path.join([base, "bin", "crun"]))

      # The tmp staging dir must be cleaned up.
      leftover =
        Path.wildcard(Path.join(System.tmp_dir!(), "glorbo_podman_extract_*"))

      assert leftover == []
    end
  end

  describe "ensure_podman/1 — checksum mismatch (Pitfall 1, T-2-10)" do
    test "returns {:error, {:checksum_mismatch, expected, actual}} and never extracts",
         %{tmp_root: tmp_root} do
      base = Path.join(tmp_root, "glorbo_home")
      bad_tar = Path.join(tmp_root, "bad.tar.gz")
      File.write!(bad_tar, "this is not a tarball")

      download_fun = fn _url, dest ->
        File.cp!(bad_tar, dest)
        {:ok, dest}
      end

      result =
        BinaryBootstrap.ensure_podman(
          which_fun: fn _ -> nil end,
          base: base,
          arch: :amd64,
          expected_sha:
            "0000000000000000000000000000000000000000000000000000000000000001",
          download_fun: download_fun
        )

      assert {:error, {:checksum_mismatch, expected, actual}} = result
      assert expected ==
               "0000000000000000000000000000000000000000000000000000000000000001"

      assert is_binary(actual) and String.length(actual) == 64

      bin_dir = Path.join(base, "bin")
      # bin_dir is mkdir_p'd before download but must stay empty on mismatch.
      assert File.ls!(bin_dir) == [],
             "No binaries must land in ~/.glorbo/bin/ on SHA mismatch"
    end
  end

  describe "ensure_podman/1 — offline tolerance (D-09)" do
    test "returns {:ok, :skipped, \"no network\"} when download reports :enetunreach",
         %{tmp_root: tmp_root} do
      base = Path.join(tmp_root, "glorbo_home")
      download_fun = fn _url, _dest -> {:error, :enetunreach} end

      result =
        BinaryBootstrap.ensure_podman(
          which_fun: fn _ -> nil end,
          base: base,
          arch: :amd64,
          download_fun: download_fun
        )

      assert {:ok, :skipped, "no network"} = result
    end
  end

  describe "ensure_ollama/1 — tar zstd missing (Pitfall 2)" do
    test "returns {:error, :tar_zstd_missing} when host tar has no zstd and no zstd binary",
         %{tmp_root: tmp_root} do
      base = Path.join(tmp_root, "glorbo_home")
      {fixture, sha} = build_zst_fixture(tmp_root)

      download_fun = fn _url, dest ->
        File.cp!(fixture, dest)
        {:ok, dest}
      end

      # tar --version output WITHOUT the string "zstd", plus which_fun that
      # returns nil for "zstd" — both detection paths fail.
      cmd_fun = fn
        "tar", ["--version"], _opts ->
          {"tar (GNU tar) 1.30\nCopyright (C) ...\n", 0}

        other, args, _opts ->
          System.cmd(other, args)
      end

      which_fun = fn
        "zstd" -> nil
        _ -> nil
      end

      result =
        BinaryBootstrap.ensure_ollama(
          which_fun: which_fun,
          base: base,
          arch: :amd64,
          expected_sha: sha,
          download_fun: download_fun,
          cmd_fun: cmd_fun
        )

      assert {:error, :tar_zstd_missing} = result
    end
  end

  describe "verify_sha256/2" do
    test "returns :ok for matching digest", %{tmp_root: tmp_root} do
      path = Path.join(tmp_root, "content.bin")
      payload = "glorbo-bootstrap-test-payload"
      File.write!(path, payload)

      sha = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

      assert :ok = BinaryBootstrap.verify_sha256(path, sha)
    end

    test "returns :error on mismatch with both expected and actual reported",
         %{tmp_root: tmp_root} do
      path = Path.join(tmp_root, "content.bin")
      File.write!(path, "payload")

      expected =
        "dead000000000000000000000000000000000000000000000000000000000000"

      assert {:error, {:checksum_mismatch, ^expected, actual}} =
               BinaryBootstrap.verify_sha256(path, expected)

      assert is_binary(actual) and String.length(actual) == 64
      assert actual != expected
    end
  end

  describe "module shape — no per-binary public functions (dispatch through ensure/2)" do
    test "no def download_(podman|ollama) or def extract_(podman|ollama) are public" do
      source = File.read!("lib/glorbo/init/binary_bootstrap.ex")
      refute Regex.match?(~r/def download_podman\(/, source)
      refute Regex.match?(~r/def download_ollama\(/, source)
      refute Regex.match?(~r/def extract_podman\(/, source)
      refute Regex.match?(~r/def extract_ollama\(/, source)
    end
  end

  # ---- fixtures ----

  defp build_podman_fixture_tar(tmp_root) do
    fixture_src = Path.join(tmp_root, "podman_src")
    usr_bin = Path.join(fixture_src, "usr/bin")
    File.mkdir_p!(usr_bin)
    File.write!(Path.join(usr_bin, "podman"), "#!/bin/sh\necho fake podman\n")
    File.write!(Path.join(usr_bin, "crun"), "#!/bin/sh\necho fake crun\n")

    tar_path = Path.join(tmp_root, "podman-fixture.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", tar_path, "-C", fixture_src, "usr"])

    sha = file_sha256(tar_path)
    {tar_path, sha}
  end

  defp build_zst_fixture(tmp_root) do
    path = Path.join(tmp_root, "ollama-fake.tar.zst")
    File.write!(path, "fake-zstd-bytes-#{System.unique_integer([:positive])}")
    {path, file_sha256(path)}
  end

  defp file_sha256(path) do
    path
    |> File.stream!([], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
