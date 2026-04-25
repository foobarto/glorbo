defmodule Glorbo.CLITest do
  use ExUnit.Case, async: true

  @moduledoc """
  Unit tests for the pure `Glorbo.CLI.dispatch/1` function used by the
  Burrito release binary's argv branch in `Glorbo.Application.start/2`.

  `dispatch/1` is a PURE function — it returns `{verb, exit_code, output}`
  without side effects. `Application.start/2` handles IO + `System.halt/1`.
  """

  alias Glorbo.CLI

  test "dispatch([]) returns :help, exit_code 0, help text" do
    {verb, code, output} = CLI.dispatch([])
    assert verb == :help
    assert code == 0
    assert output =~ "USAGE"
    assert output =~ "doctor"
    # GEP-25 R27: validate verb must appear in the help.
    assert output =~ "validate"
  end

  test "dispatch([\"validate\", PATH]) runs FileSpec validator (R27)" do
    base =
      Path.join(System.tmp_dir!(), "glorbo-cli-validate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "companies/acme"))
    # Seed a well-formed company.md — validator should return exit 0.
    File.write!(Path.join(base, "companies/acme/company.md"), """
    ---
    kind: company/v1
    slug: acme
    name: Acme
    ---
    """)

    on_exit(fn -> File.rm_rf!(base) end)

    {verb, code, output} = CLI.dispatch(["validate", base])
    assert verb == :validate
    assert code == 0
    assert output =~ "0 error"
  end

  test ~S|dispatch(["fmt", PATH]) — R33 default --check reports drift + exit 1| do
    base =
      Path.join(System.tmp_dir!(), "glorbo-cli-fmt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "companies/acme"))
    # Non-canonical key order — formatter should want to rewrite.
    File.write!(Path.join(base, "companies/acme/company.md"), """
    ---
    name: Acme
    slug: acme
    kind: company/v1
    ---
    """)

    on_exit(fn -> File.rm_rf!(base) end)

    {verb, code, output} = CLI.dispatch(["fmt", base])
    assert verb == :fmt
    assert code == 1
    assert output =~ "would rewrite"
    assert output =~ "company.md"
  end

  test ~S|dispatch(["fmt", PATH, "--write"]) applies drift + exits 0| do
    base =
      Path.join(System.tmp_dir!(), "glorbo-cli-fmt-write-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "companies/acme"))

    File.write!(Path.join(base, "companies/acme/company.md"), """
    ---
    name: Acme
    slug: acme
    kind: company/v1
    ---
    """)

    on_exit(fn -> File.rm_rf!(base) end)

    {verb, code, output} = CLI.dispatch(["fmt", base, "--write"])
    assert verb == :fmt
    assert code == 0
    assert output =~ "rewrote"

    # Second pass should be clean.
    {_, code2, output2} = CLI.dispatch(["fmt", base])
    assert code2 == 0
    assert output2 =~ "0 changed"
  end

  # GEP-32 phase 4 — `detect-providers` verb. We don't control what's
  # running on the host at test time; assert only the wiring:
  # verb routes, exit code is 0 or 1, and human output includes the
  # expected header. Per-fingerprint tests live in
  # test/glorbo/providers/detect_test.exs.
  test ~S|dispatch(["detect-providers"]) routes to the probe + reports results| do
    {verb, code, output} = CLI.dispatch(["detect-providers"])
    assert verb == :detect_providers
    assert code in [0, 1]
    assert output =~ "probed"
  end

  test ~S|dispatch(["detect-providers", "--json"]) emits one JSON object per line| do
    {verb, _code, output} = CLI.dispatch(["detect-providers", "--json"])
    assert verb == :detect_providers

    lines = output |> String.split("\n", trim: true)
    assert lines != []

    Enum.each(lines, fn line ->
      assert {:ok, %{"alias" => _, "status" => _}} = Jason.decode(line)
    end)
  end

  test ~S|dispatch(["detect-providers"]) surfaces in help text| do
    {:help, 0, help} = CLI.dispatch([])
    assert help =~ "detect-providers"
  end

  test ~S|dispatch(["validate", PATH, "--json"]) emits NDJSON summary| do
    base =
      Path.join(
        System.tmp_dir!(),
        "glorbo-cli-validate-json-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(base, "companies/acme"))
    # Seed a broken company.md — expect an error.
    File.write!(Path.join(base, "companies/acme/company.md"), """
    ---
    slug: acme
    name: Acme
    ---
    """)

    on_exit(fn -> File.rm_rf!(base) end)

    {:validate, code, output} = CLI.dispatch(["validate", base, "--json"])
    assert code == 1
    assert output =~ ~s("type":"finding")
    assert output =~ ~s("type":"summary")
    assert output =~ ~s("code":"missing_kind")
  end

  test "dispatch([\"--help\"]) returns :help" do
    {:help, 0, output} = CLI.dispatch(["--help"])
    assert output =~ "USAGE"
  end

  test "dispatch([\"-h\"]) returns :help" do
    {:help, 0, _output} = CLI.dispatch(["-h"])
  end

  test "dispatch([\"help\"]) returns :help" do
    {:help, 0, _output} = CLI.dispatch(["help"])
  end

  test "dispatch([\"doctor\"]) runs checks and returns :doctor with table output" do
    {verb, code, output} = CLI.dispatch(["doctor"])
    assert verb == :doctor
    # Phase 2 (D-45): severity-weighted exit code 0/1/2.
    assert code in [0, 1, 2]
    assert output =~ "Glorbo Doctor"

    # Phase-1 check names still present (D-44 additive-only).
    for name <- ["linux_kernel", "uidmap", "disk_space", "glorbo_dir", "erts_version"] do
      assert output =~ name
    end

    # Phase-2 / Phase-3 check names also present.
    for name <- [
          "audit_dir",
          "sockets_dir",
          "private_files",
          "tar_zstd",
          "bwrap",
          "user_namespaces"
        ] do
      assert output =~ name
    end
  end

  test ~S|dispatch(["doctor", "--json"]) returns parseable JSON| do
    {verb, _code, output} = CLI.dispatch(["doctor", "--json"])
    assert verb == :doctor
    decoded = Jason.decode!(output)
    assert decoded["version"] == to_string(Application.spec(:glorbo, :vsn))
    # GEP-31 adds `pasta` as a Linux-only Phase-3 check:
    # 5 Phase-1 + 4 Phase-2 + 3 Phase-3 = 12 checks.
    assert length(decoded["checks"]) == 12
    assert Map.has_key?(decoded, "exit_code")
    assert Map.has_key?(decoded, "all_passed")
    # Additive severity field on every check (D-44).
    assert Enum.all?(decoded["checks"], &Map.has_key?(&1, "severity"))
  end

  test "dispatch([\"reindex\"]) runs Reindex.run/1 and returns :reindex" do
    # Empty tmp home → no companies/ dir → Reindex short-circuits with
    # {:ok, %{indexed: 0, skipped: 0, deleted: 0}} without touching Repo.
    base =
      Path.join(System.tmp_dir!(), "glorbo_cli_reindex_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    prior = System.get_env("GLORBO_HOME")
    System.put_env("GLORBO_HOME", base)

    on_exit(fn ->
      if prior, do: System.put_env("GLORBO_HOME", prior), else: System.delete_env("GLORBO_HOME")
    end)

    {verb, code, output} = CLI.dispatch(["reindex"])
    assert verb == :reindex
    assert code == 0
    assert output =~ "glorbo reindex"
    assert output =~ "indexed=0"
  end

  test "dispatch([\"bogus\"]) returns :unknown with exit_code 1 and help text" do
    {verb, code, output} = CLI.dispatch(["bogus"])
    assert verb == :unknown
    assert code == 1
    assert output =~ "Unknown command: bogus"
    assert output =~ "USAGE"
  end

  test "help_text references DESIGN.md" do
    assert CLI.help_text() =~ "DESIGN.md"
  end

  test "help_text advertises the init verb (Plan 04 D-22)" do
    assert CLI.help_text() =~ "init"
    assert CLI.help_text() =~ "--force"
  end

  test "help_text advertises the native harness verb" do
    assert CLI.help_text() =~ "harness"
    assert CLI.help_text() =~ "GEP-32"
  end

  test ~S|dispatch(["harness", "--help"]) returns harness help| do
    assert {:harness, 0, out} = CLI.dispatch(["harness", "--help"])
    assert out =~ "glorbo harness"
    assert out =~ "GLORBO_REPLY_PATH"
  end

  describe ~S{dispatch(["init" | ...]) (Plan 04, D-22, D-23)} do
    alias Glorbo.Company.AuditLog
    alias Glorbo.Test.TmpGlorboHome

    setup do
      # Isolate to a tmp base by rebinding HOME for the duration of the test.
      base = TmpGlorboHome.setup()
      original_home = System.get_env("HOME")
      System.put_env("HOME", base)
      on_exit(fn -> if original_home, do: System.put_env("HOME", original_home) end)

      # Ensure no lingering named AuditLog from a prior test.
      case Process.whereis(AuditLog) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      {:ok, base: base}
    end

    test "returns :init tuple with exit_code 0/1/2 and a rendered summary", %{base: _base} do
      {verb, code, output} = CLI.dispatch(["init", "--no-example"])
      assert verb == :init
      assert code in [0, 1, 2]
      assert output =~ "Glorbo init"
      assert output =~ "Next steps:"
    end

    test ~S|dispatch(["init"]) does not reference the dropped Podman runtime| do
      {:init, _, output} = CLI.dispatch(["init", "--no-example"])
      refute output =~ "binary_bootstrap"
      refute output =~ "image_pull"
    end

    test ~S|dispatch(["init", "--force"]) parses without error| do
      {:init, _, output} = CLI.dispatch(["init", "--force", "--no-example"])
      assert output =~ "Glorbo init"
    end
  end

  describe ~S|dispatch(["doctor", "--fix"]) (Plan 05-04, D-16)| do
    test "routes --fix through Glorbo.CLI.DoctorFix.run/1" do
      # Plan 05-04 fills the fixer registry. Dispatch routes to the live
      # module; we only assert the verb atom + shape here (contents are
      # covered by doctor_fix_test and fixer_test).
      {verb, code, output} = CLI.dispatch(["doctor", "--fix", "--help"])
      assert verb == :doctor
      assert code in [0, 1, 2, 3]
      assert is_binary(output)
    end

    test "--fix with --json still routes to DoctorFix" do
      # D-27 reserves --json for read-only doctor; --fix is an action verb.
      # --help lets us assert the verb without triggering a live fixer run.
      {verb, _code, output} = CLI.dispatch(["doctor", "--fix", "--json", "--help"])
      assert verb == :doctor
      assert is_binary(output)
    end
  end

  describe ~S|dispatch(["history", ...]) (GEP-33 Phase 4)| do
    # GEP-44 follow-up from the Phase 4 security review pass: lock
    # in the dispatch shape for `history show / diff / restore` so
    # future regressions like the `--yes` inversion get caught
    # immediately instead of surfacing in manual UAT.

    setup do
      base =
        Path.join(System.tmp_dir!(), "glorbo_cli_history_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(base, "companies/acme"))
      File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: acme\n---\n")
      File.write!(Path.join(base, "config.md"), "secret_key_base: x\n")

      {:ok, %{initial_commit: initial_sha}} = Glorbo.HomeHistory.init(base: base)

      prior = System.get_env("GLORBO_HOME")
      System.put_env("GLORBO_HOME", base)

      on_exit(fn ->
        if prior, do: System.put_env("GLORBO_HOME", prior), else: System.delete_env("GLORBO_HOME")
        File.rm_rf!(base)
      end)

      {:ok, base: base, initial_sha: initial_sha}
    end

    test "history show <rev> dispatches to :history with formatted output",
         %{initial_sha: sha} do
      {verb, code, output} = CLI.dispatch(["history", "show", sha])
      assert verb == :history
      assert code == 0
      assert output =~ "glorbo: initial history import"
      assert output =~ "Author:"
    end

    test "history show without rev arg returns help" do
      {verb, code, output} = CLI.dispatch(["history", "show"])
      assert verb == :history
      assert code == 1
      assert output =~ "missing revision argument"
    end

    test "history show with hostile rev rejects via validator" do
      {verb, code, output} = CLI.dispatch(["history", "show", "--upload-pack=/bin/sh"])
      assert verb == :history
      assert code == 1
      assert output =~ "invalid revision"
    end

    test "history diff with one rev produces a diff (or empty if HEAD matches working tree)",
         %{base: base, initial_sha: initial_sha} do
      # Create a real second commit so diff has something to compare.
      File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: changed\n---\n")

      {:ok, _} =
        Glorbo.HomeHistory.commit_marked(
          [Path.join(base, "companies/acme/company.md")],
          %{actor: :director, action: "company.update", target: "x"},
          base: base
        )

      {verb, code, output} =
        CLI.dispatch([
          "history",
          "diff",
          initial_sha,
          "HEAD",
          "--path",
          "companies/acme/company.md"
        ])

      assert verb == :history
      assert code == 0
      # Diff output contains the changed name — exact format is git's
      # `diff --git`, but we just want to know we hit the dispatch.
      assert output =~ "changed"
    end

    test "history diff without rev returns help" do
      {verb, code, output} = CLI.dispatch(["history", "diff"])
      assert verb == :history
      assert code == 1
      assert output =~ "missing revision argument"
    end

    test "history restore WITHOUT --yes is a dry-run; working tree NOT mutated",
         %{base: base, initial_sha: initial_sha} do
      # Edit the file so a restore would actually do something.
      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited-not-restored\n---\n")

      {:ok, _} =
        Glorbo.HomeHistory.commit_marked(
          [path],
          %{actor: :director, action: "company.update", target: "x"},
          base: base
        )

      File.write!(path, "---\nname: edited-yet-again\n---\n")

      {verb, code, output} =
        CLI.dispatch(["history", "restore", initial_sha, "companies/acme/company.md"])

      assert verb == :history
      assert code == 0
      # Dry-run signal: "would restore" + "Re-run with --yes"
      assert output =~ "would restore"
      assert output =~ "--yes"

      # Working tree NOT mutated — file still has the latest local edit.
      assert File.read!(path) =~ "edited-yet-again"
    end

    test "history restore WITH --yes performs the restore + creates a new commit",
         %{base: base, initial_sha: initial_sha} do
      path = Path.join(base, "companies/acme/company.md")

      # Land a second commit so restoring back is a real diff.
      File.write!(path, "---\nname: changed\n---\n")

      {:ok, _} =
        Glorbo.HomeHistory.commit_marked(
          [path],
          %{actor: :director, action: "company.update", target: "x"},
          base: base
        )

      {verb, code, output} =
        CLI.dispatch([
          "history",
          "restore",
          initial_sha,
          "companies/acme/company.md",
          "--yes"
        ])

      assert verb == :history
      assert code == 0
      # Restore signal: "restored" with a new commit sha
      assert output =~ "restored"
      assert output =~ ~r/commit [a-f0-9]+/

      # Working tree restored to initial state.
      assert File.read!(path) =~ "name: acme"
      refute File.read!(path) =~ "changed"
    end

    test "history restore on excluded-scope path is rejected", %{initial_sha: sha} do
      {verb, code, output} = CLI.dispatch(["history", "restore", sha, "config.md", "--yes"])
      assert verb == :history
      assert code == 1
      assert output =~ "outside tracked scope"
    end

    test "history restore with hostile rev rejects via validator" do
      {verb, code, output} =
        CLI.dispatch([
          "history",
          "restore",
          "--upload-pack=/bin/sh",
          "companies/acme/company.md",
          "--yes"
        ])

      assert verb == :history
      assert code == 1
      assert output =~ "invalid revision"
    end

    test "history restore with hostile path rejects via validator", %{initial_sha: sha} do
      {verb, code, output} =
        CLI.dispatch(["history", "restore", sha, "../etc/passwd", "--yes"])

      assert verb == :history
      assert code == 1
      assert output =~ "invalid path"
    end

    test "history restore without args returns help" do
      {verb, code, output} = CLI.dispatch(["history", "restore"])
      assert verb == :history
      assert code == 1
      assert output =~ "missing arguments"
    end
  end

  describe ~S{dispatch(["shell" | _]) (GEP-37 Phase 0)} do
    test "shell --help returns help text" do
      {verb, code, output} = CLI.dispatch(["shell", "--help"])
      assert verb == :shell
      assert code == 0
      assert output =~ "interactive Director terminal"
      assert output =~ "GEP-37"
    end

    test "shell -h alias returns help text" do
      {:shell, 0, output} = CLI.dispatch(["shell", "-h"])
      assert output =~ "USAGE"
    end

    test "shell entry surfaces in top-level help text" do
      {:help, 0, help} = CLI.dispatch([])
      assert help =~ "shell"
      assert help =~ "[alpha]"
    end

    test "shell verb refuses launch when stdout is not a TTY" do
      # Test environment: ExUnit redirects IO; IO.ANSI.enabled? returns
      # false. Phase-0 placeholder declines to launch and reports the
      # non-TTY guard rather than dropping into the placeholder banner.
      {verb, code, output} = CLI.dispatch(["shell"])
      assert verb == :shell
      assert code == 1
      assert output =~ "not a TTY"
      assert output =~ "glorbo run"
    end
  end

  describe ~S{dispatch(["install" | _]) and ["uninstall" | _]} do
    test "install --help returns help text" do
      {verb, code, output} = CLI.dispatch(["install", "--help"])
      assert verb == :install
      assert code == 0
      assert output =~ "user-level systemd service"
      assert output =~ "--force"
      assert output =~ "--no-start"
    end

    test "uninstall --help returns help text" do
      {verb, code, output} = CLI.dispatch(["uninstall", "--help"])
      assert verb == :uninstall
      assert code == 0
      assert output =~ "disable"
      assert output =~ "remove"
    end

    test "install + uninstall surface in top-level help" do
      {:help, 0, help} = CLI.dispatch([])
      assert help =~ "install"
      assert help =~ "uninstall"
      assert help =~ "user systemd service"
    end

    test "help <verb> routes to install/uninstall help" do
      {:help, 0, install_help} = CLI.dispatch(["help", "install"])
      assert install_help =~ "glorbo install"

      {:help, 0, uninstall_help} = CLI.dispatch(["help", "uninstall"])
      assert uninstall_help =~ "glorbo uninstall"
    end
  end

  describe "Glorbo.CLI.Install.service_unit/1" do
    alias Glorbo.CLI.Install

    test "renders a valid systemd unit file" do
      unit = Install.service_unit("/usr/local/bin/glorbo")

      assert unit =~ "[Unit]"
      assert unit =~ "[Service]"
      assert unit =~ "[Install]"
      assert unit =~ "Description=Glorbo"
      assert unit =~ "Type=simple"
      assert unit =~ "ExecStart=/usr/local/bin/glorbo serve"
      assert unit =~ "Restart=on-failure"
      assert unit =~ "WantedBy=default.target"
    end

    test "shell-quotes paths containing whitespace" do
      unit = Install.service_unit("/opt/glorbo build/glorbo")
      assert unit =~ ~s|ExecStart="/opt/glorbo build/glorbo" serve|
    end

    test "leaves clean paths unquoted" do
      unit = Install.service_unit("/opt/glorbo/bin/glorbo")
      refute unit =~ ~s|ExecStart="/opt|
      assert unit =~ "ExecStart=/opt/glorbo/bin/glorbo serve"
    end
  end

  describe "Glorbo.CLI.Install.unit_path/0" do
    alias Glorbo.CLI.Install

    test "honours XDG_CONFIG_HOME when set" do
      old = System.get_env("XDG_CONFIG_HOME")
      System.put_env("XDG_CONFIG_HOME", "/tmp/xdg-config-test")

      try do
        assert Install.unit_path() ==
                 "/tmp/xdg-config-test/systemd/user/glorbo.service"
      after
        if old,
          do: System.put_env("XDG_CONFIG_HOME", old),
          else: System.delete_env("XDG_CONFIG_HOME")
      end
    end

    test "falls back to $HOME/.config when XDG_CONFIG_HOME unset" do
      old = System.get_env("XDG_CONFIG_HOME")
      System.delete_env("XDG_CONFIG_HOME")

      try do
        path = Install.unit_path()
        assert String.ends_with?(path, "/.config/systemd/user/glorbo.service")
      after
        if old, do: System.put_env("XDG_CONFIG_HOME", old)
      end
    end
  end
end
