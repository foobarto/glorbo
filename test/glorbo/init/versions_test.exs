defmodule Glorbo.Init.VersionsTest do
  use ExUnit.Case, async: true

  alias Glorbo.Init.Versions

  describe "podman version + URL + SHA256" do
    test "podman_version/0 returns v5.8.1" do
      assert Versions.podman_version() == "v5.8.1"
    end

    test "podman_url/1 returns verified amd64 URL" do
      assert Versions.podman_url(:amd64) ==
               "https://github.com/mgoltzsche/podman-static/releases/download/v5.8.1/podman-linux-amd64.tar.gz"
    end

    test "podman_url/1 returns verified arm64 URL" do
      assert Versions.podman_url(:arm64) ==
               "https://github.com/mgoltzsche/podman-static/releases/download/v5.8.1/podman-linux-arm64.tar.gz"
    end

    test "podman_sha256/1 returns the real canonical amd64 hash" do
      assert Versions.podman_sha256(:amd64) ==
               "9d5d2962cffba74a75f23cef650ed6d91542bc79e1154dceadbae66778f8eaef"
    end

    test "podman_sha256/1 returns the real canonical arm64 hash" do
      assert Versions.podman_sha256(:arm64) ==
               "7eabbced637ec9d4d4e0f15f916f6cbe838aa08f497119f6319dc89e142c0890"
    end
  end

  describe "ollama version + URL + SHA256" do
    test "ollama_version/0 returns v0.20.7" do
      assert Versions.ollama_version() == "v0.20.7"
    end

    test "ollama_url/1 returns verified amd64 URL" do
      assert Versions.ollama_url(:amd64) ==
               "https://github.com/ollama/ollama/releases/download/v0.20.7/ollama-linux-amd64.tar.zst"
    end

    test "ollama_url/1 returns verified arm64 URL" do
      assert Versions.ollama_url(:arm64) ==
               "https://github.com/ollama/ollama/releases/download/v0.20.7/ollama-linux-arm64.tar.zst"
    end

    test "ollama_sha256/1 returns the real canonical amd64 hash" do
      assert Versions.ollama_sha256(:amd64) ==
               "193c41ffee30411a76af4484dae9cdd4c2d6f8f877b7096925c36f2489af131f"
    end

    test "ollama_sha256/1 returns the real canonical arm64 hash" do
      assert Versions.ollama_sha256(:arm64) ==
               "e8816fc0ec282d6a28b920feeb89cce45edca79847217f5662b85ec77a6cc20f"
    end
  end

  describe "B6: no placeholder hashes" do
    @tag :placeholder_guard
    test "no SHA256 constant is all-zeros, all-ones, all-twos, or all-threes" do
      source = File.read!("lib/glorbo/init/versions.ex")

      refute Regex.match?(~r/"0{64}"/, source),
             "versions.ex contains an all-zero SHA256 placeholder"

      refute Regex.match?(~r/"1{64}"/, source),
             "versions.ex contains an all-one SHA256 placeholder"

      refute Regex.match?(~r/"2{64}"/, source),
             "versions.ex contains an all-two SHA256 placeholder"

      refute Regex.match?(~r/"3{64}"/, source),
             "versions.ex contains an all-three SHA256 placeholder"

      refute Regex.match?(~r/TODO[^\n]*A1/i, source),
             "versions.ex still carries a TODO-A1 placeholder marker"
    end
  end

  describe "detect_arch/0" do
    test "recognises the current host architecture" do
      assert Versions.detect_arch() in [:amd64, :arm64]
    end
  end
end
