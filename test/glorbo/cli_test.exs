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
end
