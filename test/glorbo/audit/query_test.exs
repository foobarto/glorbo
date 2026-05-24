defmodule Glorbo.Audit.QueryTest do
  @moduledoc """
  Unit tests for `Glorbo.Audit.Query.for_task/4` (#264).
  """
  use ExUnit.Case, async: true

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-audit-query-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([base, "companies/acme/audit"]))
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp seed(base, lines) do
    month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
    path = Path.join([base, "companies/acme/audit", "#{month}.jsonl"])
    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
    month
  end

  test "returns empty list when audit file is missing", %{base: base} do
    assert [] == Glorbo.Audit.Query.for_task(base, "acme", "projects/x/tasks/t-1.md")
  end

  test "matches by target == task_path", %{base: base} do
    seed(base, [
      %{
        "ts" => "2026-04-20T09:00:00Z",
        "action" => "a",
        "target" => "projects/foo/tasks/foo-1.md"
      },
      %{
        "ts" => "2026-04-20T09:01:00Z",
        "action" => "b",
        "target" => "projects/foo/tasks/other.md"
      }
    ])

    entries = Glorbo.Audit.Query.for_task(base, "acme", "projects/foo/tasks/foo-1.md")
    assert length(entries) == 1
    assert hd(entries)["action"] == "a"
  end

  test "matches by bare task_id (shorter target form)", %{base: base} do
    seed(base, [
      %{"ts" => "2026-04-20T09:00:00Z", "action" => "a", "target" => "foo-1"}
    ])

    entries = Glorbo.Audit.Query.for_task(base, "acme", "projects/foo/tasks/foo-1.md")
    assert length(entries) == 1
  end

  test "matches by detail.task_path", %{base: base} do
    seed(base, [
      %{
        "ts" => "2026-04-20T09:00:00Z",
        "action" => "a",
        "target" => "something-else",
        "detail" => %{"task_path" => "projects/foo/tasks/foo-1.md"}
      }
    ])

    entries = Glorbo.Audit.Query.for_task(base, "acme", "projects/foo/tasks/foo-1.md")
    assert length(entries) == 1
  end

  test "orders newest-first and honours limit", %{base: base} do
    seed(
      base,
      for i <- 1..10 do
        %{
          "ts" => "2026-04-20T09:0#{i}:00Z",
          "action" => "a-#{i}",
          "target" => "projects/foo/tasks/foo-1.md"
        }
      end
    )

    entries = Glorbo.Audit.Query.for_task(base, "acme", "projects/foo/tasks/foo-1.md", limit: 3)
    assert length(entries) == 3
    # Newest first: a-10, a-9, a-8.
    assert hd(entries)["action"] == "a-10"
  end

  test "silently skips malformed JSON lines", %{base: base} do
    month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
    path = Path.join([base, "companies/acme/audit", "#{month}.jsonl"])

    File.write!(path, """
    not-json
    #{Jason.encode!(%{"ts" => "2026-04-20T09:00:00Z", "action" => "ok", "target" => "projects/foo/tasks/foo-1.md"})}
    {broken
    """)

    entries = Glorbo.Audit.Query.for_task(base, "acme", "projects/foo/tasks/foo-1.md")
    assert length(entries) == 1
    assert hd(entries)["action"] == "ok"
  end

  # PR #35 (gemini round-3 F7): `:month` was interpolated into the
  # audit file path with no validation. A future caller dropping
  # request-param data through `:month` could path-traverse into
  # any JSONL on disk. Defense-in-depth: only `YYYY-MM` reaches
  # `Path.join`; anything else falls back to the current UTC month.
  describe "month option validation (gemini round-3 F7)" do
    test "well-formed month string is honoured", %{base: base} do
      # Seed an entry into a SPECIFIC non-current month and assert
      # that asking for that month with the well-formed string
      # actually returns it (proving the validation doesn't break
      # the legitimate path).
      explicit_month = "2024-07"
      path = Path.join([base, "companies/acme/audit", "#{explicit_month}.jsonl"])
      File.write!(path, Jason.encode!(%{"action" => "a", "target" => "projects/x/tasks/t.md"}))

      entries =
        Glorbo.Audit.Query.for_task(base, "acme", "projects/x/tasks/t.md", month: explicit_month)

      assert length(entries) == 1
    end

    test "malformed month falls back to current month (no path traversal)", %{base: base} do
      # Seed an entry into the current month so we can detect the
      # fallback fired (returning current-month data) rather than
      # the malicious month string having traversed elsewhere.
      seed(base, [%{"action" => "current", "target" => "projects/x/tasks/t.md"}])

      for bad <- [
            "../../etc",
            "../../../tmp/secret",
            "2024-13",
            "24-07",
            "2024-7",
            "2024-07/extra",
            "../2024-07",
            "2024-07.jsonl",
            "1234-99",
            ""
          ] do
        entries =
          Glorbo.Audit.Query.for_task(base, "acme", "projects/x/tasks/t.md", month: bad)

        # Should return the current-month entry (fallback applied);
        # if the malicious month string had escaped into Path.join,
        # we'd be reading from a different file path entirely.
        assert length(entries) == 1, "expected current-month fallback for #{inspect(bad)}"
        assert hd(entries)["action"] == "current"
      end
    end

    test "non-binary month opt falls back without crashing", %{base: base} do
      seed(base, [%{"action" => "current", "target" => "projects/x/tasks/t.md"}])

      for bad <- [:atom_month, 202_407, nil, %{not: :a, month: :string}] do
        entries =
          Glorbo.Audit.Query.for_task(base, "acme", "projects/x/tasks/t.md", month: bad)

        assert length(entries) == 1, "expected current-month fallback for #{inspect(bad)}"
      end
    end
  end
end
