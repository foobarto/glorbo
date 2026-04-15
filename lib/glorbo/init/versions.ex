defmodule Glorbo.Init.Versions do
  @moduledoc """
  Pinned versions + URLs + SHA256s for the two third-party binaries Glorbo
  bootstraps (podman-static and ollama).

  **Update procedure.** The Glorbo release engineer recomputes SHA256s
  against the new upstream tags, updates this module, and the tests verify
  the hash shape against fixtures. NEVER trust upstream "latest" — always
  pin explicit versions (D-02).

  **Q-A1 resolution (2026-04-15).** mgoltzsche/podman-static ships GPG `.asc`
  signatures only; ollama ships `sha256sum.txt`. Rather than split the
  verification path, Glorbo embeds canonical SHA256s computed from the
  actual upstream artifacts at plan revision time. There are **no**
  placeholder values — D-03 is fully delivered.

  **Q-2 resolution (Ollama build choice).** The bundled ollama tarball is
  the CPU-only `.tar.zst`. Only `usr/bin/ollama` is copied out at install
  time — the ~1.9 GB of accelerator runtimes in `usr/lib/ollama/` are
  skipped. Director adds GPU support manually if needed; a `--with-gpu`
  flag is deferred to a later phase.

  See `.planning/phases/02-filesystem-foundation-container-runtime-local-llm/02-02-PLAN.md`
  for the full rationale + open questions.
  """

  @podman_version "v5.8.1"
  @ollama_version "v0.20.7"

  # Real canonical hashes — computed 2026-04-15 from upstream release artifacts.
  # Verify upstream: `curl -fsSL <url> | sha256sum`.
  @podman_sha256 %{
    amd64: "9d5d2962cffba74a75f23cef650ed6d91542bc79e1154dceadbae66778f8eaef",
    arm64: "7eabbced637ec9d4d4e0f15f916f6cbe838aa08f497119f6319dc89e142c0890"
  }
  @ollama_sha256 %{
    amd64: "193c41ffee30411a76af4484dae9cdd4c2d6f8f877b7096925c36f2489af131f",
    arm64: "e8816fc0ec282d6a28b920feeb89cce45edca79847217f5662b85ec77a6cc20f"
  }

  @spec podman_version() :: String.t()
  def podman_version, do: @podman_version

  @spec ollama_version() :: String.t()
  def ollama_version, do: @ollama_version

  @spec podman_url(:amd64 | :arm64) :: String.t()
  def podman_url(arch) when arch in [:amd64, :arm64] do
    "https://github.com/mgoltzsche/podman-static/releases/download/#{@podman_version}/podman-linux-#{arch}.tar.gz"
  end

  @spec ollama_url(:amd64 | :arm64) :: String.t()
  def ollama_url(arch) when arch in [:amd64, :arm64] do
    "https://github.com/ollama/ollama/releases/download/#{@ollama_version}/ollama-linux-#{arch}.tar.zst"
  end

  @spec podman_sha256(:amd64 | :arm64) :: String.t()
  def podman_sha256(arch), do: Map.fetch!(@podman_sha256, arch)

  @spec ollama_sha256(:amd64 | :arm64) :: String.t()
  def ollama_sha256(arch), do: Map.fetch!(@ollama_sha256, arch)

  @spec detect_arch() :: :amd64 | :arm64
  def detect_arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() do
      "x86_64" <> _ -> :amd64
      "aarch64" <> _ -> :arm64
      other -> raise "Unsupported architecture: #{other}"
    end
  end
end
