defmodule GlorboWeb.AuditExportControllerTest do
  use GlorboWeb.ConnCase, async: false

  setup do
    # See SearchControllerTest for context — ConnCase doesn't set
    # `:glorbo_base`. Each case owns + restores it so order-dependent
    # state from other test files doesn't leak in.
    base = Glorbo.Test.TmpGlorboHome.setup()
    original = Application.get_env(:glorbo, :glorbo_base)
    Application.put_env(:glorbo, :glorbo_base, base)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:glorbo, :glorbo_base)
        val -> Application.put_env(:glorbo, :glorbo_base, val)
      end
    end)

    month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
    path = Path.join([base, "companies", "acme", "audit", "#{month}.jsonl"])
    File.mkdir_p!(Path.dirname(path))

    lines = [
      Jason.encode!(%{
        "ts" => "2026-04-21T10:00:00Z",
        "actor" => "director",
        "action" => "chat.post",
        "target" => "channels/general.md",
        "detail" => %{"channel" => "general"}
      }),
      Jason.encode!(%{
        "ts" => "2026-04-21T10:01:00Z",
        "actor" => "ceo",
        "action" => "agent.complete",
        "target" => "projects/foo/tasks/t-01.md",
        "detail" => %{"exit_status" => "0", "note" => "has, commas and \"quotes\""}
      })
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")

    :ok
  end

  test "returns CSV with header + seeded rows", %{conn: conn} do
    conn = get(conn, "/companies/acme/audit.csv")

    assert response(conn, 200)
    body = conn.resp_body

    # Header row
    assert body =~ "ts,actor,action,target,detail\n"

    # First row (simple)
    assert body =~ "2026-04-21T10:00:00Z,director,chat.post,channels/general.md,"

    # Second row — detail with commas + quotes must be CSV-escaped
    # per RFC 4180: embedded `"` becomes `""`, whole value quoted.
    assert body =~ "ceo,agent.complete,projects/foo/tasks/t-01.md,"
    # JSON-encoded detail contains `\"quotes\"`; CSV escape doubles
    # each `"` to `""`, leaving the backslash pair intact.
    assert body =~ ~s|has, commas and \\""quotes\\""|
  end

  test "sends the right Content-Disposition", %{conn: conn} do
    conn = get(conn, "/companies/acme/audit.csv")
    [disp | _] = get_resp_header(conn, "content-disposition")
    assert disp =~ "attachment; filename=\"acme-audit-"
    assert disp =~ ".csv\""
  end

  test "returns CSV header only when no audit file exists", %{conn: conn} do
    base = Application.fetch_env!(:glorbo, :glorbo_base)
    File.rm_rf!(Path.join([base, "companies/acme/audit"]))

    conn = get(conn, "/companies/acme/audit.csv")
    assert response(conn, 200) == "ts,actor,action,target,detail\n"
  end

  test "rejects invalid slug with 400", %{conn: conn} do
    conn = get(conn, "/companies/BAD!/audit.csv")
    assert response(conn, 400) == "invalid company slug"
  end

  # Gap #8 (P1): an audit-log export is sensitive data behind the passphrase
  # gate. Prove a request WITHOUT a director session (even with a valid bearer
  # token) is bounced to /login by DirectorAuth — the export is passphrase-gated,
  # not token-gated.
  test "without a director session it is bounced to /login (not token-gated)" do
    token = Application.get_env(:glorbo, :dashboard_token, "test-token")

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> Plug.Test.init_test_session(%{})
      |> get("/companies/acme/audit.csv")

    assert redirected_to(conn) == "/login"
  end
end
