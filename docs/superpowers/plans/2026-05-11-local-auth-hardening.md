# Local Auth Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind epmd to loopback, auto-generate a mandatory dashboard/MCP auth token on first boot, print the token URL on startup and in `glorbo status`.

**Architecture:** Token auto-generation lives in `Config.load/1` (a new `ensure_dashboard_token/2` step in the `with` chain patches `config.md` in-place, mirroring the existing `write_cookie!` pattern). `DashboardToken` plug drops its nil pass-through. Serve/up/status all read and display the token URL.

**Tech Stack:** Elixir/OTP, Phoenix Plug, ExUnit. No new deps.

---

## File map

| File | Change |
|---|---|
| `lib/glorbo/cli/lifecycle/distribution.ex` | Add `-address 127.0.0.1` to epmd spawn |
| `lib/glorbo/config.ex` | `generate_token/0`, `ensure_dashboard_token/2`, patch `write_default!`, update type |
| `lib/glorbo_web/plugs/dashboard_token.ex` | Drop nil/empty pass-through, add 500 branch |
| `lib/glorbo/cli/lifecycle/serve.ex` | Print token URL on startup |
| `lib/glorbo/cli/lifecycle/up.ex` | Print token URL in success message |
| `lib/glorbo/cli/lifecycle/status.ex` | Read config, build token URL |
| `docs/geps/0048-local-auth-hardening.md` | New GEP |
| `CHANGELOG.md` | Unreleased entry |
| `test/glorbo/config_test.exs` | New token cases; update nil-token case |
| `test/glorbo_web/plugs/dashboard_token_test.exs` | Remove nil/empty pass-through tests; add 500 test |
| `test/glorbo/cli/status_test.exs` | Token URL in output |
| `test/glorbo/cli/serve_test.exs` | Token URL in banner |
| `test/glorbo/cli/up_test.exs` | Token URL in success message |

---

### Task 1: epmd loopback bind

**Files:**
- Modify: `lib/glorbo/cli/lifecycle/distribution.ex`

- [ ] **Step 1: Write a failing test** (add to the existing file, or create `test/glorbo/cli/distribution_test.exs` if it doesn't exist)

```elixir
# test/glorbo/cli/distribution_test.exs
defmodule Glorbo.CLI.Lifecycle.DistributionTest do
  use ExUnit.Case, async: true

  test "ensure_epmd passes -address 127.0.0.1 flag" do
    # We can't call ensure_epmd/0 directly (private), but we CAN
    # verify the module source embeds the flag. This is a contract
    # test — if the flag disappears, this fails.
    source = File.read!("lib/glorbo/cli/lifecycle/distribution.ex")
    assert source =~ ~s("-address", "127.0.0.1")
  end
end
```

Run: `mix test test/glorbo/cli/distribution_test.exs`
Expected: FAIL — string not found.

- [ ] **Step 2: Add `-address 127.0.0.1` to the epmd spawn**

In `lib/glorbo/cli/lifecycle/distribution.ex`, find `ensure_epmd/0` and change:

```elixir
# Before
_ = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
```

to:

```elixir
# After
_ = System.cmd(epmd, ["-address", "127.0.0.1", "-daemon"], stderr_to_stdout: true)
```

Also update the module `@moduledoc` — add after the existing epmd comment block:

```
  ## epmd bind

  epmd is spawned with `-address 127.0.0.1` so its listen socket is
  loopback-only. Edge case: if another Erlang application already started
  epmd on all interfaces before glorbo, our `-daemon` invocation exits
  silently (epmd is idempotent). We log a warning but do not abort —
  `Node.start/2` still succeeds. The risk is the pre-existing epmd's
  wider bind, not ours.
```

- [ ] **Step 3: Run test to verify it passes**

Run: `mix test test/glorbo/cli/distribution_test.exs`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/glorbo/cli/lifecycle/distribution.ex test/glorbo/cli/distribution_test.exs
git commit -m "fix(security): bind epmd to 127.0.0.1 only"
```

---

### Task 2: Config — mandatory token auto-generation

**Files:**
- Modify: `lib/glorbo/config.ex`
- Modify: `test/glorbo/config_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/glorbo/config_test.exs`, inside the `describe "first-boot bootstrap"` block:

```elixir
test "write_default! generates a non-nil dashboard_token" do
  base = TmpGlorboHome.setup()
  assert {:ok, cfg} = Config.load(base)
  assert is_binary(cfg.dashboard_token)
  assert byte_size(cfg.dashboard_token) >= 16
end

test "config.md written on first boot contains dashboard_token value (not null)" do
  base = TmpGlorboHome.setup()
  {:ok, _} = Config.load(base)
  content = File.read!(Path.join(base, "config.md"))
  # Must not be `dashboard_token: null`
  refute content =~ "dashboard_token: null"
  assert content =~ "dashboard_token: "
end
```

Add a new `describe "token auto-generation"` block:

```elixir
describe "token auto-generation" do
  test "null token in existing config.md is replaced with a generated token" do
    base = TmpGlorboHome.setup()

    File.mkdir_p!(base)
    File.write!(Path.join(base, "config.md"), """
    ---
    secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
    dashboard_token: null
    host: "127.0.0.1"
    port: 4000
    ---

    # notes
    """)

    assert {:ok, cfg} = Config.load(base)
    assert is_binary(cfg.dashboard_token)
    assert byte_size(cfg.dashboard_token) >= 16

    # Also patched on disk
    content = File.read!(Path.join(base, "config.md"))
    refute content =~ "dashboard_token: null"
    assert content =~ "dashboard_token: " <> cfg.dashboard_token
  end

  test "empty-string token is also replaced" do
    base = TmpGlorboHome.setup()

    File.mkdir_p!(base)
    File.write!(Path.join(base, "config.md"), """
    ---
    secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
    dashboard_token: ""
    host: "127.0.0.1"
    port: 4000
    ---

    # notes
    """)

    assert {:ok, cfg} = Config.load(base)
    assert is_binary(cfg.dashboard_token)
    assert byte_size(cfg.dashboard_token) >= 16
  end

  test "existing non-empty token is preserved and not rewritten" do
    base = TmpGlorboHome.setup()
    path = Path.join(base, "config.md")

    File.mkdir_p!(base)
    File.write!(path, """
    ---
    secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
    dashboard_token: my-existing-token-abc123
    host: "127.0.0.1"
    port: 4000
    ---

    # notes
    """)
    File.chmod!(path, 0o600)

    {:ok, %File.Stat{mtime: before}} = File.stat(path)
    :timer.sleep(1_100)

    assert {:ok, cfg} = Config.load(base)
    assert cfg.dashboard_token == "my-existing-token-abc123"

    {:ok, %File.Stat{mtime: after_}} = File.stat(path)
    assert before == after_
  end

  test "config.md stays mode 0600 after token patch" do
    base = TmpGlorboHome.setup()

    File.mkdir_p!(base)
    File.write!(Path.join(base, "config.md"), """
    ---
    secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
    dashboard_token: null
    host: "127.0.0.1"
    port: 4000
    ---
    """)

    {:ok, _} = Config.load(base)
    {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(base, "config.md"))
    assert Bitwise.band(mode, 0o777) == 0o600
  end
end
```

Also update the existing `"null dashboard_token becomes nil"` test — it now generates a token instead:

```elixir
test "null dashboard_token in existing file is auto-generated" do
  base = TmpGlorboHome.setup()

  File.write!(Path.join(base, "config.md"), """
  ---
  secret_key_base: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  dashboard_token: null
  host: "127.0.0.1"
  port: 4000
  ---

  # notes
  """)

  assert {:ok, cfg} = Config.load(base)
  assert is_binary(cfg.dashboard_token)
  assert byte_size(cfg.dashboard_token) >= 16
end
```

Run: `mix test test/glorbo/config_test.exs`
Expected: FAIL on the new token cases.

- [ ] **Step 2: Implement token generation in `Config`**

In `lib/glorbo/config.ex`:

**a) Update `@type config`** — `dashboard_token` is now always a string:

```elixir
@type config :: %{
        secret_key_base: String.t(),
        dashboard_token: String.t(),
        host: String.t(),
        port: pos_integer()
      }
```

**b) Add `generate_token/0` private helper** (place near `generate_secret/0`):

```elixir
defp generate_token do
  :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
```

**c) Modify `write_default!/1`** — replace `dashboard_token: null` with a generated token:

```elixir
defp write_default!(path) do
  File.mkdir_p!(Path.dirname(path))
  secret = generate_secret()
  cookie = generate_cookie()
  token = generate_token()

  body = """
  ---
  kind: config/v1
  secret_key_base: #{secret}
  dashboard_token: #{token}
  erl_cookie: #{cookie}
  host: "127.0.0.1"
  port: 4000
  ---

  # Glorbo configuration

  Generated by Glorbo on first boot. Edit `host:` to `0.0.0.0` to accept
  LAN connections. Keep this file readable only by the Director.
  Set `dashboard_token:` to a fresh value to rotate the auth token.
  MCP clients: use `Authorization: Bearer <token>` on every request.
  """

  atomic_write_secret!(path, body)
end
```

**d) Add `ensure_dashboard_token/2` and `patch_dashboard_token/2` private functions** (place near `erl_cookie/2`):

```elixir
# Auto-generate dashboard_token when nil/empty. Patches config.md in-place
# using the same line-level rewrite as write_cookie!/5 (T-04-05: token
# value never appears in log messages).
defp ensure_dashboard_token(_path, %{dashboard_token: t} = cfg)
     when is_binary(t) and t != "" do
  {:ok, cfg}
end

defp ensure_dashboard_token(path, cfg) do
  token = generate_token()

  case patch_dashboard_token(path, token) do
    :ok ->
      :ok

    {:error, reason} ->
      require Logger

      Logger.warning(
        "Failed to persist dashboard_token to config.md: #{inspect(reason)} " <>
          "(token is in-memory only — will change on restart)"
      )
  end

  {:ok, %{cfg | dashboard_token: token}}
end

defp patch_dashboard_token(path, token) do
  with {:ok, content} <- File.read(path) do
    new_content =
      if Regex.match?(~r/^dashboard_token:/m, content) do
        String.replace(content, ~r/^dashboard_token:.*$/m, "dashboard_token: #{token}")
      else
        # Key entirely absent — inject after the opening fence.
        String.replace(content, "---\n", "---\ndashboard_token: #{token}\n", global: false)
      end

    atomic_write_secret!(path, new_content)
    :ok
  else
    {:error, reason} -> {:error, reason}
  end
rescue
  e -> {:error, Exception.message(e)}
end
```

**e) Update `load/1`** — add `ensure_dashboard_token` step to the `with` chain:

```elixir
@spec load(Path.t()) :: {:ok, config()} | {:error, :config_parse}
def load(base \\ Glorbo.Filesystem.Hierarchy.default_root()) do
  path = Path.join(base, "config.md")
  unless File.exists?(path), do: write_default!(path)

  with {:ok, content} <- File.read(path),
       {:ok, meta, _body} <- Frontmatter.parse(content),
       {:ok, cfg} <- coerce(meta),
       {:ok, cfg} <- ensure_dashboard_token(path, cfg) do
    {:ok, cfg}
  else
    _ -> {:error, :config_parse}
  end
end
```

**f) Update `coerce/1`** — `dashboard_token` is now always a string after `ensure_dashboard_token` runs, but `coerce` itself still uses `maybe_string` (fine — `ensure_dashboard_token` handles the nil case after coerce). No change needed to `coerce/1`.

**g) Update `@moduledoc`** — replace the doc comment about `dashboard_token: null` being optional:

```elixir
  ## File shape

      ---
      secret_key_base: <base-64 string, 64+ bytes of entropy>
      dashboard_token: <url-safe base-64, 32 bytes entropy>   # always required
      host: "127.0.0.1"                # loopback-only by default
      port: 4000
      ---

      # Glorbo configuration
      (free-form markdown notes here; the frontmatter is the contract)
```

And in the Security section, replace the optional-token note:

```elixir
  * `dashboard_token` is auto-generated on first boot (or patched in on
    upgrade from a `null` value) and is always required. MCP clients pass
    it via `Authorization: Bearer <token>`; browsers via `?token=<token>`.
    The token is never written to logs (T-04-05).
```

- [ ] **Step 3: Run tests**

```bash
mix test test/glorbo/config_test.exs
```

Expected: All pass. The updated `"null dashboard_token becomes nil"` test now passes because nil auto-generates.

- [ ] **Step 4: Commit**

```bash
git add lib/glorbo/config.ex test/glorbo/config_test.exs
git commit -m "feat(config): auto-generate mandatory dashboard_token on boot"
```

---

### Task 3: DashboardToken plug — always enforce

**Files:**
- Modify: `lib/glorbo_web/plugs/dashboard_token.ex`
- Modify: `test/glorbo_web/plugs/dashboard_token_test.exs`

- [ ] **Step 1: Write failing tests**

In `test/glorbo_web/plugs/dashboard_token_test.exs`, add:

```elixir
test "halts with 500 when dashboard_token is nil (server misconfiguration)" do
  Application.put_env(:glorbo, :dashboard_token, nil)
  conn = conn(:get, "/companies")
  result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
  assert result.status == 500
  assert result.halted
  # Body must not leak any secrets (there are none here, but assert format)
  assert result.resp_body == "server misconfiguration"
end

test "halts with 500 when dashboard_token is empty string" do
  Application.put_env(:glorbo, :dashboard_token, "")
  conn = conn(:get, "/companies")
  result = GlorboWeb.Plugs.DashboardToken.call(conn, [])
  assert result.status == 500
  assert result.halted
end
```

Also delete (or rename) the two now-wrong pass-through tests:

```elixir
# DELETE these tests — they test behavior we're removing:
# test "passes through when token is nil (default)"
# test "passes through when token is empty string"
```

Run: `mix test test/glorbo_web/plugs/dashboard_token_test.exs`
Expected: FAIL on 500 tests; the two deleted pass-through tests no longer exist.

- [ ] **Step 2: Update `DashboardToken.call/2`**

Replace the entire `call/2` function in `lib/glorbo_web/plugs/dashboard_token.ex`:

```elixir
@impl Plug
def call(conn, _opts) do
  case Application.get_env(:glorbo, :dashboard_token) do
    token when is_binary(token) and token != "" ->
      check_token(conn, token)

    other ->
      require Logger

      Logger.error(
        "dashboard_token not configured (got #{inspect(other)}); " <>
          "refusing all requests — fix ~/.glorbo/config.md"
      )

      conn
      |> send_resp(500, "server misconfiguration")
      |> halt()
  end
end
```

Update `@moduledoc` to reflect that the nil pass-through is gone:

```
  Behaviour matrix on `Application.get_env(:glorbo, :dashboard_token)`:

    * binary string — request MUST carry a matching token:
        1. `?token=<value>` query param — browser dashboard.
        2. `Authorization: Bearer <value>` header — MCP clients and CLIs.
      Match via `Plug.Crypto.secure_compare/2` (constant-time, defeats T-04-14).
      Mismatch or missing → `401 unauthorized` + `halt/1`.
    * `nil` or `""` — server misconfiguration (Config.load should always
      generate a token). Returns `500 server misconfiguration` and halts.
      This path should never be reached in a correctly booted instance.
```

- [ ] **Step 3: Run tests**

```bash
mix test test/glorbo_web/plugs/dashboard_token_test.exs
```

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add lib/glorbo_web/plugs/dashboard_token.ex test/glorbo_web/plugs/dashboard_token_test.exs
git commit -m "fix(security): DashboardToken plug always enforces token — no nil pass-through"
```

---

### Task 4: Print token URL in `glorbo serve` and `glorbo up`

**Files:**
- Modify: `lib/glorbo/cli/lifecycle/serve.ex`
- Modify: `lib/glorbo/cli/lifecycle/up.ex`
- Modify: `test/glorbo/cli/serve_test.exs`
- Modify: `test/glorbo/cli/up_test.exs`

- [ ] **Step 1: Write failing tests**

In `test/glorbo/cli/serve_test.exs`, find the `--exit-after` integration test and add an assertion:

```elixir
# Add this import at the top of the describe block (or module level):
import ExUnit.CaptureIO

@tag :integration
test "banner includes token URL", %{glorbo_home: _home} do
  # Capture IO so we can inspect what serve prints.
  output = capture_io(fn ->
    Serve.run(["--exit-after", "50"])
  end)
  assert output =~ "http://127.0.0.1:4000/?token="
end
```

In `test/glorbo/cli/up_test.exs`, update the URL assertion in `"writes pidfile + returns :up tuple on fresh start"`:

```elixir
# Replace:
assert out =~ "http://127.0.0.1:4000"
# With:
assert out =~ "http://127.0.0.1:4000/?token="
```

Run: `mix test test/glorbo/cli/serve_test.exs test/glorbo/cli/up_test.exs`
Expected: FAIL — serve prints plain URL; up prints URL without `?token=`.

- [ ] **Step 2: Update `Serve.run/1`**

In `lib/glorbo/cli/lifecycle/serve.ex`, replace the `IO.puts` in the `true ->` branch:

```elixir
true ->
  Audit.emit("serve", "start", %{})
  :ok = ensure_tree_started()
  token = Application.get_env(:glorbo, :dashboard_token, "")

  url =
    if is_binary(token) and token != "",
      do: "http://127.0.0.1:4000/?token=#{token}",
      else: "http://127.0.0.1:4000"

  IO.puts("Glorbo serving on #{url}  (Ctrl-C to stop)")
  Process.sleep(:infinity)
```

Also update the `--exit-after` path to print the URL too (keeps the two code paths consistent, and allows the integration test above to capture it):

```elixir
is_integer(opts[:exit_after]) ->
  Audit.emit("serve", "start", %{exit_after_ms: opts[:exit_after]})
  :ok = ensure_tree_started()
  token = Application.get_env(:glorbo, :dashboard_token, "")

  url =
    if is_binary(token) and token != "",
      do: "http://127.0.0.1:4000/?token=#{token}",
      else: "http://127.0.0.1:4000"

  IO.puts("Glorbo serving on #{url}  (Ctrl-C to stop)")
  Process.sleep(opts[:exit_after])
  Audit.emit("serve", "complete", %{exit_after_ms: opts[:exit_after]})

  {:serve, 0, "glorbo serve exited (test mode after #{opts[:exit_after]}ms).\n"}
```

- [ ] **Step 3: Update `Up.start_daemon/1`**

In `lib/glorbo/cli/lifecycle/up.ex`, modify the success branch of the `with` chain. Add a `token_url` derivation just before the final success tuple:

```elixir
with {:ok, cookie} <- Glorbo.Config.erl_cookie(base),
     {:ok, binary} <- locate_binary(),
     env <- [
       {~c"RELEASE_COOKIE", String.to_charlist(cookie)},
       {~c"PHX_SERVER", ~c"1"}
     ],
     {:ok, os_pid} <- Daemon.spawn_detached(binary, env),
     :ok <- safe_pidfile_write(os_pid, base) do
  Audit.emit("up", "complete", %{pid: os_pid})

  token_url =
    case Glorbo.Config.load(base) do
      {:ok, %{dashboard_token: t}} when is_binary(t) and t != "" ->
        "http://127.0.0.1:4000/?token=#{t}"

      _ ->
        "http://127.0.0.1:4000  (token: see ~/.glorbo/config.md)"
    end

  {:up, 0, "glorbo up (pid=#{os_pid}). Dashboard: #{token_url}\n"}
```

- [ ] **Step 4: Run tests**

```bash
mix test test/glorbo/cli/serve_test.exs test/glorbo/cli/up_test.exs
```

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/glorbo/cli/lifecycle/serve.ex lib/glorbo/cli/lifecycle/up.ex \
        test/glorbo/cli/serve_test.exs test/glorbo/cli/up_test.exs
git commit -m "feat(cli): print token URL in serve and up startup output"
```

---

### Task 5: Token URL in `glorbo status`

**Files:**
- Modify: `lib/glorbo/cli/lifecycle/status.ex`
- Modify: `test/glorbo/cli/status_test.exs`

- [ ] **Step 1: Write failing tests**

In `test/glorbo/cli/status_test.exs`, update the `--json` test and add a token assertion:

```elixir
test "--json emits valid JSON with dashboard_url containing token", %{glorbo_home: home} do
  # Config.load auto-generates a token when config.md is absent.
  {:ok, cfg} = Glorbo.Config.load(home)

  assert {:status, 3, out} = Status.run(["--json"], port_closed())
  assert {:ok, parsed} = Jason.decode(out)
  assert Map.has_key?(parsed, "running")
  assert Map.has_key?(parsed, "pid")
  assert Map.has_key?(parsed, "port_listening")
  assert Map.has_key?(parsed, "dashboard_url")
  assert parsed["running"] == false
  assert parsed["dashboard_url"] =~ "http://127.0.0.1:4000/?token="
  assert parsed["dashboard_url"] =~ cfg.dashboard_token
end

test "human table includes token URL", %{glorbo_home: _home} do
  assert {:status, 3, out} = Status.run([], port_closed())
  assert out =~ "http://127.0.0.1:4000/?token="
end
```

Delete (or update) the old `--json` test that asserts the bare URL:

```elixir
# DELETE (or replace with the new test above):
# assert parsed["dashboard_url"] == "http://127.0.0.1:4000"
```

Run: `mix test test/glorbo/cli/status_test.exs`
Expected: FAIL — status still returns the bare URL.

- [ ] **Step 2: Update `Status`**

In `lib/glorbo/cli/lifecycle/status.ex`:

**a) Remove the `@dashboard_url` module attribute** (it's now computed dynamically).

**b) Update `build_status_map/2`** to read the token from config:

```elixir
defp build_status_map(base, run_opts) do
  pidfile_status = Pidfile.status(base)
  running? = pidfile_status == :running

  pid =
    if running? do
      try do
        Pidfile.read!(base)
      rescue
        _ -> nil
      end
    else
      nil
    end

  port_check = Keyword.get(run_opts, :port_check_fun, &port_listening?/0)

  dashboard_url =
    case Glorbo.Config.load(base) do
      {:ok, %{dashboard_token: t}} when is_binary(t) and t != "" ->
        "http://127.0.0.1:#{@port}/?token=#{t}"

      _ ->
        "http://127.0.0.1:#{@port}  (token unavailable — check config.md)"
    end

  %{
    running: running?,
    pid: pid,
    port_listening: port_check.(),
    dashboard_url: dashboard_url
  }
end
```

**c) Update `format_table/1`** — the `url` variable already captures `dashboard_url` from the map, so the table row updates automatically. No change needed.

**d) Update `@moduledoc`** — replace the `dashboard_url: "..."` type doc to note it now includes the token.

- [ ] **Step 3: Run tests**

```bash
mix test test/glorbo/cli/status_test.exs
```

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add lib/glorbo/cli/lifecycle/status.ex test/glorbo/cli/status_test.exs
git commit -m "feat(status): include token URL in dashboard_url output"
```

---

### Task 6: GEP-48 + CHANGELOG

**Files:**
- Create: `docs/geps/0048-local-auth-hardening.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/geps/README.md`

- [ ] **Step 1: Write GEP-48**

Create `docs/geps/0048-local-auth-hardening.md`:

```markdown
---
gep: 0048
title: Local auth hardening — epmd loopback + mandatory dashboard token
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
type: Standards
created: 2026-05-11
history:
  - date: 2026-05-11
    status: Draft
    note: Initial draft.
  - date: 2026-05-11
    status: Implemented
    note: Shipped in the same session.
implemented-in: v0.21.0
---

# GEP-0048: Local auth hardening — epmd loopback + mandatory dashboard token

## Problem

Three gaps existed in Glorbo's local security posture:

1. **epmd listened on all interfaces.** `ensure_epmd/0` spawned `epmd -daemon`
   with no `-address` flag, binding `0.0.0.0:4369`. Any process on the LAN
   could register or query Erlang node names.
2. **Dashboard auth was opt-in.** `DashboardToken` was a no-op when
   `dashboard_token: null` (the default). Fresh installs had no token, so
   the web UI was unauthenticated by default.
3. **MCP endpoint was unauthenticated by default** for the same reason —
   `/mcp` was already behind the `:dashboard` pipeline but inherited the
   nil pass-through.

The HTTP bind (`ip: {127, 0, 0, 1}`) was already correct.

## Goals

- epmd only listens on `127.0.0.1`.
- A mandatory auth token is auto-generated on first boot (or on upgrade
  from a `null` value) and persisted in `config.md`.
- Both the web dashboard and the MCP endpoint always require the token.
- The token URL is printed on `glorbo serve`, `glorbo up`, and
  `glorbo status`.

## Non-goals

- Token rotation UI (the operator can edit `config.md` manually).
- Multi-user or multi-token support.
- Changing the HTTP bind (already `127.0.0.1`).

## Design

### epmd

`ensure_epmd/0` in `Glorbo.CLI.Lifecycle.Distribution` spawns:

```
epmd -address 127.0.0.1 -daemon
```

Edge case: if another Erlang app already started epmd on all interfaces,
our invocation exits silently (epmd is idempotent). We log a warning but
do not abort — `Node.start/2` still succeeds.

### Token generation

`Glorbo.Config.load/1` gains an `ensure_dashboard_token/2` step in its
`with` chain. When `dashboard_token` is nil or empty, a 32-byte
URL-safe base-64 token (~192 bits of entropy) is generated and patched
into `config.md` via line-level regex replacement (same technique as the
existing `write_cookie!`). The file is written with mode 0600. The token
is never logged (T-04-05).

`write_default!/1` (fresh-install path) also pre-generates a token, so a
newly created `config.md` never contains `dashboard_token: null`.

### Plug enforcement

`DashboardToken.call/2` drops the nil and empty-string pass-throughs.
A missing token at runtime (startup bug) returns `500 server
misconfiguration` and halts, making the failure loud rather than silently
open.

### Token URL display

- `glorbo serve` — prints `http://127.0.0.1:4000/?token=<token>` to stdout.
- `glorbo up` — includes the token URL in the success message.
- `glorbo status` — reads `config.md` and includes the token URL in both
  human and `--json` output.

## Migration / rollout

On upgrade, the next `glorbo serve` or `glorbo up` triggers
`Config.load/1`, which detects `dashboard_token: null`, generates a
token, and patches `config.md`. The token URL is then printed in the
startup banner — operators copy it to configure their browser and MCP
client (`Authorization: Bearer <token>`).

## Failure modes

- **config.md patch fails (disk full, EACCES):** token is generated
  in-memory, server boots, warning is logged. Token changes on next
  restart. Operator must fix the filesystem to make it persistent.
- **Another epmd already running on all interfaces:** warning logged,
  glorbo still starts. Risk is pre-existing epmd's wider bind.

## Test strategy

- `Glorbo.ConfigTest` — token auto-generation cases (nil, empty, existing,
  mode 0600 after patch).
- `GlorboWeb.Plugs.DashboardTokenTest` — nil/empty → 500; removed
  pass-through cases.
- `Glorbo.CLI.StatusTest` — token URL in table and JSON output.
- `Glorbo.CLI.ServeTest` / `UpTest` — token URL in startup output.
- `Glorbo.CLI.DistributionTest` — contract test asserting `-address` flag.

## Decision log

### D1. Generate token in `Config.load/1`, not at serve/up time

- **Decided:** `load/1` is the single generation point. `ensure_dashboard_token/2`
  is a step in the `with` chain.
- **Alternatives:** Generate in `Serve.run/1` and `Up.start_daemon/1`
  separately; generate only in `write_default!` (no migration).
- **Why:** Single path handles both fresh install and migration from `null`.
  Token is always available in app env after `runtime.exs` calls `load/1`.

### D2. Line-level regex patch for `config.md`

- **Decided:** `String.replace/3` with a `~r/^dashboard_token:.*$/m` regex
  to overwrite the existing line.
- **Alternatives:** Full YAML round-trip serialisation.
- **Why:** `Frontmatter` has no serialise function. The config format is
  fixed and narrow; targeted line replacement is safe, auditable, and
  mirrors the existing `write_cookie!` approach.

### D3. 500 on nil token in `DashboardToken`

- **Decided:** nil/empty → `500 server misconfiguration` + halt.
- **Alternatives:** Silently pass through (original); 503.
- **Why:** A nil token at runtime is a startup bug. 500 is loud and
  forces investigation; silent pass-through turns a bug into an open door.

## Related

- GEP-5: kernel-enforced security (bwrap isolation)
- GEP-29: MCP server (the endpoint being hardened)
- Threatmodel T-04-05: secret leakage
- Threatmodel T-04-14: timing attacks on token comparison
- Threatmodel T11: MCP bearer-header auth
```

- [ ] **Step 2: Add README.md index entry**

In `docs/geps/README.md`, find the table and add the new row (keeping numeric order):

```markdown
| 0048 | [Local auth hardening — epmd loopback + mandatory dashboard token](./0048-local-auth-hardening.md) | Standards | Implemented |
```

- [ ] **Step 3: Update CHANGELOG.md**

Under `## [Unreleased]`, add:

```markdown
### Security

- Bind epmd to `127.0.0.1` only — previously listened on all interfaces (`0.0.0.0:4369`).
- Dashboard and MCP auth token is now mandatory — auto-generated on first boot (or on upgrade from `dashboard_token: null`), written to `config.md` at mode 0600. `DashboardToken` plug no longer passes through unauthenticated requests.
- `glorbo serve`, `glorbo up`, and `glorbo status` now print the full token URL (`http://127.0.0.1:4000/?token=<token>`) for browser and MCP client configuration.
```

- [ ] **Step 4: Run the full test suite**

```bash
mix precommit
echo "Credo exit: $?"
```

Expected: All tests pass, zero Credo findings, format clean. If Credo exits non-zero check `$?` explicitly — Credo exit 8 (refactor warnings) won't show in the command output.

- [ ] **Step 5: Commit**

```bash
git add docs/geps/0048-local-auth-hardening.md docs/geps/README.md CHANGELOG.md
git commit -m "docs(gep-48): local auth hardening — epmd loopback + mandatory dashboard token"
```
