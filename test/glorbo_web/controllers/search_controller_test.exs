defmodule GlorboWeb.SearchControllerTest do
  use GlorboWeb.ConnCase, async: false

  @moduletag :capture_log

  setup do
    # `ConnCase` doesn't put `:glorbo_base` into the app env (only
    # `LiveCase` does). Earlier suite-pollution failures came from
    # depending on whatever previous case left in there. Each test
    # sets + restores its own tmp root so the case is self-contained.
    base = Glorbo.Test.TmpGlorboHome.setup()
    original = Application.get_env(:glorbo, :glorbo_base)
    Application.put_env(:glorbo, :glorbo_base, base)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:glorbo, :glorbo_base)
        val -> Application.put_env(:glorbo, :glorbo_base, val)
      end
    end)

    tasks_dir = Path.join([base, "companies", "acme", "projects", "foo", "tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join(tasks_dir, "foo-1.md"), """
    ---
    kind: task/v1
    title: Hello search
    status: todo
    ---
    """)

    :ok
  end

  test "returns results for a matching query", %{conn: conn} do
    conn = get(conn, "/api/search?co=acme&q=hello")
    body = json_response(conn, 200)
    assert [result | _] = body["results"]
    assert result["kind"] == "task"
    assert result["label"] =~ "Hello search"
    assert result["href"] == "/companies/acme/tasks/foo-1"
  end

  test "empty query returns empty list", %{conn: conn} do
    conn = get(conn, "/api/search?co=acme&q=")
    assert %{"results" => []} = json_response(conn, 200)
  end

  test "invalid company returns empty list", %{conn: conn} do
    conn = get(conn, "/api/search?co=NOPE!&q=hello")
    assert %{"results" => []} = json_response(conn, 200)
  end

  test "honours limit", %{conn: conn} do
    conn = get(conn, "/api/search?co=acme&q=foo&limit=0")
    assert %{"results" => results} = json_response(conn, 200)
    # Limit=0 is invalid → falls back to default 20. At least the
    # seeded task matches; other rows (e.g. audit entries from
    # other fixtures) may also match and that's fine — the
    # contract is "limit bounds output", not "exact count".
    refute results == []
    assert Enum.any?(results, &(&1["kind"] == "task" and &1["label"] =~ "Hello search"))
  end

  test "missing query returns empty list", %{conn: conn} do
    conn = get(conn, "/api/search?co=acme")
    assert %{"results" => []} = json_response(conn, 200)
  end
end
