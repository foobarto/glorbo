defmodule Mix.Tasks.Glorbo.ReleaseFormula do
  @moduledoc """
  Regenerate the Homebrew formula for the current `mix.exs` version,
  pulling sha256 sums from the already-published GitHub release
  asset manifest.

      mix glorbo.release_formula [--tap-path PATH] [--write]

  By default the task prints the rendered formula to stdout and
  exits 0. Pass `--write` to overwrite `<tap-path>/Formula/glorbo.rb`
  in place.

  `--tap-path` defaults to `../homebrew-tap` (sibling checkout).

  ## Typical flow after a release

      gh release create vX.Y.Z ...          # upload binaries + SHA256SUMS
      mix glorbo.release_formula --write    # regenerate the formula
      (cd ../homebrew-tap && git commit -am "glorbo vX.Y.Z" && git push)

  The task fetches
  `https://github.com/foobarto/glorbo/releases/download/vX.Y.Z/SHA256SUMS`
  over HTTP and parses the two-column `<sha>  <filename>` lines.
  Fails loudly if the release or the expected assets are missing.
  """
  use Mix.Task

  @shortdoc "Regenerate the Homebrew formula for the current mix.exs version"

  @repo "foobarto/glorbo"
  @tap_formula_path "Formula/glorbo.rb"
  @sha256_re ~r/\A[0-9a-f]{64}\z/i
  # Linux binaries are the minimum shipped set; the `build-macos` CI
  # job is currently disabled (see `.github/workflows/ci.yml`), so
  # darwin SHAs are optional. When they're present the formula
  # includes `on_macos do` blocks; when they're absent the formula
  # is Linux-only and `depends_on :linux` keeps `brew install` from
  # trying on macOS. Restore darwin to `@required_linux_assets` once
  # `build-macos` is re-enabled.
  @required_linux_assets [
    "glorbo-linux-x86_64",
    "glorbo-linux-aarch64"
  ]
  @optional_darwin_assets [
    "glorbo-darwin-x86_64",
    "glorbo-darwin-arm64"
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [tap_path: :string, write: :boolean, version: :string]
      )

    version = Keyword.get(opts, :version) || Mix.Project.config()[:version]
    tap_path = Keyword.get(opts, :tap_path, "../homebrew-tap")

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    shas = fetch_sha256sums(version)
    validate_assets!(shas)

    formula = render_formula(version, shas)

    if opts[:write] do
      target = Path.join(tap_path, @tap_formula_path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, formula)
      IO.puts("✓ wrote #{target} (version=#{version})")
    else
      IO.puts(formula)
    end
  end

  # ------------------------------------------------------------------
  # SHA256 fetch
  # ------------------------------------------------------------------

  defp fetch_sha256sums(version) do
    url =
      "https://github.com/#{@repo}/releases/download/v#{version}/SHA256SUMS"

    case :httpc.request(:get, {to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        parse_sha256sums(body)

      {:ok, {{_, status, reason}, _, _}} ->
        Mix.raise(
          "SHA256SUMS fetch failed for v#{version}: HTTP #{status} #{reason}\n" <>
            "URL: #{url}\n\n" <>
            "Is the GitHub release published? Was SHA256SUMS uploaded?"
        )

      {:error, reason} ->
        Mix.raise("SHA256SUMS fetch failed: #{inspect(reason)}")
    end
  end

  @doc false
  def parse_sha256sums(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ~r/\s+/, parts: 2, trim: true) do
        [sha, filename] ->
          sha = String.trim(sha) |> String.downcase()
          filename = filename |> String.trim() |> String.trim_leading("*")

          cond do
            filename == "" ->
              Mix.raise("Malformed SHA256SUMS line (blank filename): #{inspect(line)}")

            not valid_sha256?(sha) ->
              Mix.raise("Malformed SHA256SUMS line (invalid sha256): #{inspect(line)}")

            true ->
              Map.put(acc, filename, sha)
          end

        _ ->
          Mix.raise("Malformed SHA256SUMS line: #{inspect(line)}")
      end
    end)
  end

  @doc false
  def validate_assets!(shas) do
    for asset <- @required_linux_assets do
      unless Map.has_key?(shas, asset) do
        Mix.raise(
          "SHA256SUMS missing required asset `#{asset}` — did the release " <>
            "ship both x86_64 and aarch64 Linux Burrito binaries?"
        )
      end

      unless valid_sha256?(Map.fetch!(shas, asset)) do
        Mix.raise("SHA256SUMS contains invalid sha256 for required asset `#{asset}`")
      end
    end

    # Darwin assets are optional while `build-macos` is disabled in CI.
    # If either is present, both must be present AND valid — a half
    # set would generate a broken macOS formula branch.
    darwin_present = Enum.filter(@optional_darwin_assets, &Map.has_key?(shas, &1))

    cond do
      darwin_present == [] ->
        :ok

      length(darwin_present) != length(@optional_darwin_assets) ->
        Mix.raise(
          "SHA256SUMS has only some darwin assets; expected all of " <>
            "#{inspect(@optional_darwin_assets)} or none"
        )

      Enum.any?(@optional_darwin_assets, fn a -> not valid_sha256?(Map.fetch!(shas, a)) end) ->
        Mix.raise("SHA256SUMS contains invalid sha256 for one of the darwin assets")

      true ->
        :ok
    end
  end

  @doc false
  def darwin_present?(shas) do
    Enum.all?(@optional_darwin_assets, &Map.has_key?(shas, &1))
  end

  defp valid_sha256?(sha) when is_binary(sha), do: Regex.match?(@sha256_re, sha)
  defp valid_sha256?(_), do: false

  # ------------------------------------------------------------------
  # Formula rendering
  # ------------------------------------------------------------------

  defp render_formula(version, shas) do
    linux_x86 = Map.fetch!(shas, "glorbo-linux-x86_64")
    linux_arm = Map.fetch!(shas, "glorbo-linux-aarch64")
    darwin? = darwin_present?(shas)

    version_regex = String.replace(version, ".", "\\\\.")

    header = formula_header(version, darwin?)
    linux_block = linux_block(version, linux_x86, linux_arm)
    macos_block = if darwin?, do: macos_block(version, shas), else: ""
    linux_gate = if darwin?, do: "", else: "  depends_on :linux\n\n"
    install_block = install_block(darwin?)
    caveats = caveats_block(darwin?)
    test_block = test_block(version_regex)

    """
    #{header}
    class Glorbo < Formula
      desc "Filesystem-first agent orchestration (Elixir/OTP + Phoenix LiveView)"
      homepage "https://github.com/foobarto/glorbo"
      version "#{version}"
      license "Apache-2.0"

    #{linux_gate}#{linux_block}#{macos_block}#{install_block}

    #{caveats}

    #{test_block}
    end
    """
  end

  defp formula_header(_version, darwin?) do
    platform_line =
      if darwin? do
        "# Pre-1.0. Linux: full kernel-sandboxed agent runtime via bwrap\n" <>
          "# (GEP-5). macOS: degraded mode — agents run unsandboxed because\n" <>
          "# bwrap has no macOS equivalent yet. See caveats."
      else
        "# Pre-1.0. Linux-only while the CI `build-macos` matrix is\n" <>
          "# disabled (see .github/workflows/ci.yml). macOS users build\n" <>
          "# from source via `mix release` until it's re-enabled."
      end

    """
    # typed: false
    # frozen_string_literal: true

    # Homebrew formula for Glorbo — filesystem-first agent orchestration.
    #
    #{platform_line}
    #
    # AUTO-GENERATED by `mix glorbo.release_formula` — do not edit
    # by hand. Regenerate after each release:
    #
    #   gh release create vX.Y.Z ...
    #   mix glorbo.release_formula --write
    """
    |> String.trim_trailing()
  end

  defp linux_block(version, linux_x86, linux_arm) do
    """
      on_linux do
        # bwrap is the kernel-enforced sandbox around every agent
        # subprocess (GEP-5 D4). Linux-only: macOS has no equivalent
        # yet.
        depends_on "bubblewrap"

        on_intel do
          url "https://github.com/foobarto/glorbo/releases/download/v#{version}/glorbo-linux-x86_64"
          sha256 "#{linux_x86}"
        end

        on_arm do
          url "https://github.com/foobarto/glorbo/releases/download/v#{version}/glorbo-linux-aarch64"
          sha256 "#{linux_arm}"
        end
      end
    """
  end

  defp macos_block(version, shas) do
    macos_x86 = Map.fetch!(shas, "glorbo-darwin-x86_64")
    macos_arm = Map.fetch!(shas, "glorbo-darwin-arm64")

    """

      on_macos do
        on_intel do
          url "https://github.com/foobarto/glorbo/releases/download/v#{version}/glorbo-darwin-x86_64"
          sha256 "#{macos_x86}"
        end

        on_arm do
          url "https://github.com/foobarto/glorbo/releases/download/v#{version}/glorbo-darwin-arm64"
          sha256 "#{macos_arm}"
        end
      end
    """
  end

  defp install_block(darwin?) do
    if darwin? do
      """

        def install
          # Burrito ships a single self-contained binary. Pick the right
          # downloaded file by OS + CPU and rename to `glorbo`.
          binary =
            if OS.mac?
              Hardware::CPU.intel? ? "glorbo-darwin-x86_64" : "glorbo-darwin-arm64"
            else
              Hardware::CPU.intel? ? "glorbo-linux-x86_64" : "glorbo-linux-aarch64"
            end

          bin.install binary => "glorbo"
          chmod 0755, bin/"glorbo"
        end
      """
    else
      """

        def install
          # Burrito ships a single self-contained binary. Only Linux
          # binaries are published right now; `depends_on :linux`
          # guards against running this branch on macOS.
          binary = Hardware::CPU.intel? ? "glorbo-linux-x86_64" : "glorbo-linux-aarch64"
          bin.install binary => "glorbo"
          chmod 0755, bin/"glorbo"
        end
      """
    end
  end

  defp caveats_block(darwin?) do
    platform_notes =
      if darwin? do
        """
              Linux  — agents run in a bwrap-sandboxed subprocess (GEP-5).
                       `brew install bubblewrap` is declared as a dep.

              macOS  — experimental. Agents run UNSANDBOXED because bwrap
                       has no macOS equivalent yet. `glorbo doctor` flags
                       this with a warning; a single audit row lands at
                       first dispatch (`agent.sandbox_unavailable`).
                       FSEvents covers the filesystem-watcher side.
        """
      else
        """
              Linux-only build — `build-macos` in the glorbo CI matrix
              is disabled while GHA macOS runners queue indefinitely.
              macOS users can build from source (`mix release`) until
              it's re-enabled.
        """
      end

    """
      def caveats
        <<~EOS
          Glorbo is pre-1.0. APIs, CLI flags, on-disk layout, and the
          SQLite schema may change between minor versions.

          First-run setup:
            glorbo doctor          # verify host prerequisites
            glorbo init            # scaffold ~/.glorbo/ with an acme example
            glorbo up              # start the dashboard on :4000

          Platform notes:

    #{String.trim_trailing(platform_notes)}

          Docs: \#{homepage}
        EOS
      end
    """
    |> String.trim_trailing()
  end

  defp test_block(version_regex) do
    """
      test do
        # Doctor in JSON mode returns the version + check list.
        output = shell_output("\#{bin}/glorbo doctor --json")
        assert_match(/"version":\\s*"#{version_regex}"/, output)
        assert_match(/"checks":/, output)
      end
    """
    |> String.trim_trailing()
  end
end
