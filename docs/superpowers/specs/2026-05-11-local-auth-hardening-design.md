# Local Auth Hardening — Design Spec

**Date:** 2026-05-11  
**Status:** Approved  
**GEP:** 48 (to be written)  
**Scope:** epmd loopback bind + mandatory dashboard/MCP auth token

---

## Problem

Three gaps in Glorbo's local security posture:

1. **epmd listens on all interfaces.** `ensure_epmd/0` spawns `epmd -daemon` with no `-address` flag, so epmd binds `0.0.0.0:4369`. Any process on the LAN can register or query Erlang node names.
2. **Dashboard auth is opt-in.** `DashboardToken` plug is a no-op when `dashboard_token` is `null` (the default). Fresh installs have no token, so the web UI is unauthenticated by default.
3. **MCP endpoint is unauthenticated by default** for the same reason — `/mcp` is already gated by the `:dashboard` pipeline but inherits the same nil-passthrough.

The HTTP bind (`ip: {127, 0, 0, 1}`) is already correct and requires no change.

---

## Design

### 1. epmd — loopback bind

**File:** `lib/glorbo/cli/lifecycle/distribution.ex`

Change the `ensure_epmd/0` invocation from:

```elixir
System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
```

to:

```elixir
System.cmd(epmd, ["-address", "127.0.0.1", "-daemon"], stderr_to_stdout: true)
```

**Edge case:** if another Erlang application already started epmd on all interfaces before glorbo, our `-daemon` invocation exits silently (epmd is idempotent). The existing wide-bind epmd stays. We log a warning via `Logger.warning/1` but do not abort — `Node.start/2` still succeeds, and the risk is the pre-existing epmd's bind, not ours. This is documented in the module doc.

No vm.args.eex change needed — `inet_dist_listen_min/max 0` already limits the distribution port to ephemeral, which is orthogonal to the epmd bind.

---

### 2. Mandatory dashboard token — `Glorbo.Config`

**File:** `lib/glorbo/config.ex`

**`write_default!/1`** — generate token on fresh install. Replace `dashboard_token: null` in the written frontmatter template with a generated token:

```elixir
token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
```

This is 43 URL-safe characters (~192 bits of entropy). Written at mode 0600 (already enforced).

**`coerce/1`** — auto-migrate existing installs. After parsing frontmatter, if `dashboard_token` is nil or `""`:
1. Generate a new token.
2. Patch `config.md` in-place: read the raw file, replace the `dashboard_token: null` (or `dashboard_token: ""`) line with `dashboard_token: <token>` via a targeted `Regex.replace/3`, write back at 0600. `Frontmatter` has no serialise path, so raw-file patching is correct here; the format is fixed and we're changing exactly one field.
3. Return the populated config — the token is always a non-empty binary from `coerce/1` onward.
4. If the patch write fails (disk full, EACCES), log `Logger.warning/1` with the error reason (no token value in the log — T-04-05) and return the in-memory token. It won't survive restart but the server boots.

**Type change:** `dashboard_token` field in `@type config` changes from `String.t() | nil` to `String.t()`.

**`config.md` comment** — update the inline comment for `dashboard_token:` to explain it is auto-generated and required; document the `Authorization: Bearer <token>` header for MCP clients.

---

### 3. `DashboardToken` plug — always enforce

**File:** `lib/glorbo_web/plugs/dashboard_token.ex`

Drop the nil and empty-string pass-through clauses. New `call/2`:

```elixir
def call(conn, _opts) do
  case Application.get_env(:glorbo, :dashboard_token) do
    token when is_binary(token) and token != "" ->
      check_token(conn, token)

    other ->
      Logger.error("dashboard_token not configured (got #{inspect(other)}); refusing all requests")
      conn |> send_resp(500, "server misconfiguration") |> halt()
  end
end
```

The 500 branch is defense-in-depth for a startup bug (Config.load failed to generate a token), not a normal path. It makes misconfiguration loud rather than silently open.

Token check mechanics unchanged: `Plug.Crypto.secure_compare/2` (constant-time), accepts `?token=<value>` query param or `Authorization: Bearer <value>` header. Both web UI and MCP clients work as-is.

---

### 4. Token URL in startup output

**File:** `lib/glorbo/cli/lifecycle/serve.ex`

Replace:
```
Glorbo serving on http://127.0.0.1:4000 (Ctrl-C to stop)
```
with:
```
Glorbo serving on http://127.0.0.1:4000/?token=<token>  (Ctrl-C to stop)
```

Token is read from `Application.get_env(:glorbo, :dashboard_token)` — already loaded into app env by `runtime.exs` → `Config.load`. Never written to the audit log.

**File:** `lib/glorbo/cli/lifecycle/up.ex`

Replace success message:
```
glorbo up (pid=12345). Dashboard: http://127.0.0.1:4000
```
with:
```
glorbo up (pid=12345). Dashboard: http://127.0.0.1:4000/?token=<token>
```

Token read from config via `Glorbo.Config.load(base)` (same base already used in `start_daemon/1`). If load fails, fall back to bare URL with `(token: see ~/.glorbo/config.md)` appended.

---

### 5. Token URL in `glorbo status`

**File:** `lib/glorbo/cli/lifecycle/status.ex`

`build_status_map/2` calls `Glorbo.Config.load(base)` and constructs:

```
dashboard_url: "http://127.0.0.1:#{port}/?token=#{token}"
```

Fallback to `"http://127.0.0.1:#{port}"` if config load fails, with a `(token unavailable — check config.md)` note appended in the human-readable table row. The `--json` output's `dashboard_url` field gets the same token-bearing URL.

Token is not a separate field in the JSON output — it lives inside the URL. The URL is already the documented contract for the `dashboard_url` key.

---

## What does NOT change

- HTTP bind — already `{127, 0, 0, 1}`.
- MCP route (`/mcp`) — already behind `:dashboard` pipeline; no router changes.
- `Authorization: Bearer` + `?token=` mechanics in `DashboardToken` — already correct.
- `config.md` file format/frontmatter schema — `dashboard_token:` field already exists; we just stop writing `null` there.
- Audit log — token never appears in any audit entry.

---

## Files changed

| File | Change |
|---|---|
| `lib/glorbo/cli/lifecycle/distribution.ex` | Add `-address 127.0.0.1` to epmd spawn |
| `lib/glorbo/config.ex` | Auto-generate token in `write_default!/1` and `coerce/1`; update type; update config comment |
| `lib/glorbo/file_spec/config_md.ex` | Update description for `dashboard_token` field |
| `lib/glorbo_web/plugs/dashboard_token.ex` | Drop nil/empty pass-through; add 500 on misconfiguration |
| `lib/glorbo/cli/lifecycle/serve.ex` | Print token URL |
| `lib/glorbo/cli/lifecycle/up.ex` | Print token URL |
| `lib/glorbo/cli/lifecycle/status.ex` | Read config, build token URL |
| `docs/geps/0048-local-auth-hardening.md` | New GEP |
| `CHANGELOG.md` | Unreleased entry |

---

## Tests

- `Glorbo.ConfigTest` — new cases: `coerce/1` with nil token generates and patches; `write_default!/1` includes non-nil token; type assertion `dashboard_token` is always binary.
- `GlorboWeb.Plugs.DashboardTokenTest` — drop nil/empty pass-through cases; add 500 misconfiguration case.
- `Glorbo.CLI.Lifecycle.StatusTest` — token URL appears in table and JSON output; fallback when config load fails.
- `Glorbo.CLI.Lifecycle.ServeTest` / `UpTest` — token URL in printed output.
- `Glorbo.CLI.Lifecycle.DistributionTest` — epmd spawned with `-address 127.0.0.1` flag.

---

## Security properties after this change

| Surface | Before | After |
|---|---|---|
| epmd | Binds 0.0.0.0:4369 | Binds 127.0.0.1:4369 |
| Web UI | Unauthenticated by default | Always token-gated |
| MCP `/mcp` | Unauthenticated by default | Always token-gated (`Authorization: Bearer`) |
| Distribution port | Ephemeral, loopback node name | Unchanged (already ephemeral + loopback) |
| HTTP bind | 127.0.0.1 | Unchanged |
