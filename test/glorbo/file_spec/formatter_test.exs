defmodule Glorbo.FileSpec.FormatterTest do
  @moduledoc """
  Tests for `Glorbo.FileSpec.Formatter` (GEP-25 R33).

  Covers:
    * Idempotence: format(format(x)) == format(x).
    * Canonical key ordering per spec module.
    * Body byte-preservation.
    * Fence normalisation.
    * JSON/JSONL skip.
    * Unknown-path skip.
    * Atomic write path (roundtrip through disk).
  """
  use ExUnit.Case, async: true

  alias Glorbo.FileSpec.Formatter

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-fmt-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp seed(base, rel, content) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  describe "format_content/2 — canonical key ordering" do
    test "company.md keys reorder to canonical" do
      content = """
      ---
      name: Acme
      slug: acme
      kind: company/v1
      ---
      Body.
      """

      {:ok, :changed, out} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", content)

      # CompanyMd canonical order: [:kind, :slug, :name, ...]
      lines = String.split(out, "\n")
      # First line after `---`: kind.
      assert Enum.at(lines, 1) == "kind: company/v1"
      assert Enum.at(lines, 2) == "slug: acme"
      assert Enum.at(lines, 3) == "name: Acme"
    end

    test "already-canonical content is :unchanged" do
      content = """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      ---
      Body.
      """

      {:ok, change, _out} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", content)

      assert change == :unchanged
    end

    test "unknown keys land alphabetically after known block" do
      content = """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      z_unknown: last
      a_unknown: first
      ---
      """

      {:ok, :changed, out} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", content)

      # Expect: kind, slug, name, then unknowns alphabetically.
      lines = String.split(out, "\n")
      assert Enum.at(lines, 1) == "kind: company/v1"
      a_idx = Enum.find_index(lines, &String.starts_with?(&1, "a_unknown:"))
      z_idx = Enum.find_index(lines, &String.starts_with?(&1, "z_unknown:"))
      assert a_idx < z_idx
    end
  end

  describe "format_content/2 — body preservation" do
    test "body is byte-for-byte preserved" do
      content =
        ~s"""
        ---
        kind: company/v1
        slug: acme
        name: Acme
        ---
        # Acme

        Custom prose with:
          - tabs\tand spaces
          - blank lines

          trailing → text.
        """

      {:ok, _change, out} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", content)

      # Extract body (everything after the 2nd `---\n`).
      [_head, body] = String.split(out, "---\n", parts: 3) |> tl()
      assert body =~ "Custom prose with"
      assert body =~ "tabs\tand spaces"
      assert body =~ "blank lines"
      assert body =~ "trailing → text."
    end
  end

  describe "format_content/2 — idempotence" do
    test "format(format(x)) == format(x)" do
      content = """
      ---
      name: Acme
      slug: acme
      kind: company/v1
      description: Test
      z_extra: z
      a_extra: a
      ---

      Body.
      """

      {:ok, _, once} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", content)

      {:ok, :unchanged, twice} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", once)

      assert once == twice
    end
  end

  describe "format_content/2 — skip cases" do
    test "JSON files are :skipped" do
      content = ~s({"kind":"inbox-archive/v1","keys":[]})

      {:ok, :skipped, out} =
        Formatter.format_content(
          "/fake/.glorbo/companies/acme/audit/_inbox_archive.json",
          content
        )

      assert out == content
    end

    test "JSONL files are :skipped" do
      content =
        ~s({"kind":"audit-event/v1","ts":"2026-04-21T00:00:00Z","actor":"system","action":"test"}\n)

      {:ok, :skipped, out} =
        Formatter.format_content("/fake/.glorbo/companies/acme/audit/2026-04.jsonl", content)

      assert out == content
    end

    test "unknown path is :skipped" do
      {:ok, :skipped, out} =
        Formatter.format_content("/tmp/unrelated-note.md", "nothing to see")

      assert out == "nothing to see"
    end

    test "missing frontmatter leaves content :unchanged" do
      {:ok, :unchanged, out} =
        Formatter.format_content(
          "/fake/.glorbo/companies/acme/company.md",
          "No frontmatter at all.\n"
        )

      assert out == "No frontmatter at all.\n"
    end
  end

  describe "format_content/2 — fence normalisation" do
    test "leading blank lines before `---` removed" do
      content = """


      ---
      kind: company/v1
      slug: acme
      name: Acme
      ---
      Body.
      """

      {:ok, :changed, out} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", content)

      refute String.starts_with?(out, "\n")
      assert String.starts_with?(out, "---\n")
    end

    test "ensures trailing newline" do
      content = "---\nkind: company/v1\nslug: acme\nname: Acme\n---\nBody."

      {:ok, :changed, out} =
        Formatter.format_content("/fake/.glorbo/companies/acme/company.md", content)

      assert String.ends_with?(out, "\n")
    end
  end

  describe "format_content/2 — list-of-maps indentation" do
    # Regression: before the fix, continuation keys inside a
    # list-of-map item were emitted at the dash column instead of
    # aligned with the first key. `paths: [%{path: /x, mode: read}]`
    # formatted as
    #     paths:
    #       - mode: read
    #       path: /x
    # which is not valid YAML. Correct output is
    #     paths:
    #       - mode: read
    #         path: /x
    test "list-of-map item continuation keys align with first key" do
      content = """
      ---
      kind: path-request/v1
      task_id: deploy-01
      paths:
        - path: /etc/config.yaml
          mode: read
        - path: /var/log/app.log
          mode: write
      reason: Need config + log during deploy.
      ---
      """

      {:ok, _, formatted} =
        Formatter.format_content(
          "/fake/.glorbo/companies/acme/agents/ceo/outbox/path-request-deploy-01.md",
          content
        )

      assert formatted =~ "paths:\n  - mode: read\n    path: /etc/config.yaml\n"
      assert formatted =~ "  - mode: write\n    path: /var/log/app.log\n"
      # No spurious 2-space continuation (dash column indent):
      refute formatted =~ "\n  path: /etc/config.yaml"
      refute formatted =~ "\n  path: /var/log/app.log"
    end

    test "list-of-map canonical form is idempotent" do
      canonical = """
      ---
      kind: path-request/v1
      task_id: deploy-01
      paths:
        - mode: read
          path: /etc/config.yaml
      reason: Reading config during deploy.
      ---
      """

      {:ok, :unchanged, out} =
        Formatter.format_content(
          "/fake/.glorbo/companies/acme/agents/ceo/outbox/path-request-deploy-01.md",
          canonical
        )

      assert out == canonical
    end
  end

  describe "check_path/1 + write_path/1" do
    test "check_path reports drift but does not write", %{base: base} do
      path =
        seed(base, "companies/acme/company.md", """
        ---
        name: Acme
        slug: acme
        kind: company/v1
        ---
        Body.
        """)

      original = File.read!(path)

      %{changed: changed, stats: stats} = Formatter.check_path(base)
      assert path in changed
      assert stats.changed == 1
      assert File.read!(path) == original
    end

    test "write_path applies the formatter atomically", %{base: base} do
      path =
        seed(base, "companies/acme/company.md", """
        ---
        name: Acme
        slug: acme
        kind: company/v1
        ---
        Body.
        """)

      %{changed: changed, stats: stats} = Formatter.write_path(base)
      assert path in changed
      assert stats.changed == 1

      # After write, a re-check should be clean.
      %{changed: changed2} = Formatter.check_path(base)
      assert changed2 == []

      # Atomic: no leftover .tmp files.
      tmps = Path.wildcard(Path.join(base, "**/*.tmp.*"))
      assert tmps == []
    end

    test "round-trip: check → write → check is a no-op second time", %{base: base} do
      seed(base, "companies/acme/company.md", """
      ---
      name: Acme
      slug: acme
      kind: company/v1
      ---
      """)

      %{stats: s1} = Formatter.write_path(base)
      assert s1.changed == 1

      %{stats: s2} = Formatter.write_path(base)
      assert s2.changed == 0
      assert s2.unchanged == 1
    end
  end
end
