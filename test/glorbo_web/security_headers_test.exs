defmodule GlorboWeb.SecurityHeadersTest do
  @moduledoc """
  Wave 28b — assert the `:browser` pipeline emits the explicit
  Content-Security-Policy header set by `put_secure_browser_headers/2`
  in `GlorboWeb.Router`. Locks the policy in so a future router
  refactor can't silently drop it.

  Phoenix's default `put_secure_browser_headers` does NOT set CSP;
  Glorbo overlays an explicit map argument. If that argument
  disappears, this test fails.
  """
  use GlorboWeb.ConnCase, async: false

  test "GET /companies emits a Content-Security-Policy header", %{conn: conn} do
    conn = get(conn, ~p"/health-legacy")
    [csp] = get_resp_header(conn, "content-security-policy")

    # Must default-deny everything not explicitly allowed.
    assert csp =~ "default-src 'self'"
    # Must not allow external script loads.
    assert csp =~ "script-src 'self'"
    # Must not allow framing (clickjacking defense).
    assert csp =~ "frame-ancestors 'none'"
    # Must scope LiveView WS to same-origin.
    assert csp =~ "connect-src 'self'"
    # Must restrict <base href> hijack.
    assert csp =~ "base-uri 'self'"
    # Must restrict form submission targets.
    assert csp =~ "form-action 'self'"
  end

  test "Phoenix's default secure headers also present", %{conn: conn} do
    conn = get(conn, ~p"/health-legacy")
    # Phoenix's defaults (`x-content-type-options: nosniff`, etc.)
    # ride along on top of the user map. We assert one canonical
    # default to catch a hypothetical regression where the custom
    # map argument is misinterpreted as a *replacement* for the
    # whole secure-header set.
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
  end
end
