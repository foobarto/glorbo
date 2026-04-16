---
phase: 04-liveview-dashboard-real-time-channels
reviewed: 2026-04-16T00:00:00Z
depth: standard
files_reviewed: 34
files_reviewed_list:
  - lib/glorbo/config.ex
  - lib/glorbo/filesystem/watcher.ex
  - lib/glorbo/task_definition.ex
  - lib/glorbo/application.ex
  - lib/glorbo_web/actions.ex
  - lib/glorbo_web/stdout_streamer.ex
  - lib/glorbo_web/markdown.ex
  - lib/glorbo_web/plugs/dashboard_token.ex
  - lib/glorbo_web/router.ex
  - lib/glorbo_web/live/overview_live.ex
  - lib/glorbo_web/live/company_live.ex
  - lib/glorbo_web/live/kanban_live.ex
  - lib/glorbo_web/live/agent_live.ex
  - lib/glorbo_web/live/approval_queue_live.ex
  - lib/glorbo_web/live/channel_live.ex
  - lib/glorbo_web/live/audit_live.ex
  - lib/glorbo_web/live/health_live.ex
  - lib/glorbo_web/components/icon.ex
  - lib/glorbo_web/components/sidebar.ex
  - lib/glorbo_web/components/tab_bar.ex
  - lib/glorbo_web/components/channel_message.ex
  - lib/glorbo_web/components/audit_entry.ex
  - lib/glorbo_web/components/health_dot.ex
  - lib/glorbo_web/components/budget_ring.ex
  - lib/glorbo_web/components/stdout_tail.ex
  - lib/glorbo_web/components/company_card.ex
  - lib/glorbo_web/components/agent_card.ex
  - lib/glorbo_web/components/task_card.ex
  - lib/glorbo_web/components/approval_card.ex
  - lib/glorbo_web/components/layouts.ex
  - lib/glorbo_web/components/layouts/app.html.heex
  - lib/glorbo_web/components/layouts/root.html.heex
  - lib/glorbo_web/controllers/error_html.ex
  - lib/glorbo_web/controllers/page_controller.ex
  - mix.exs
  - config/config.exs
  - config/dev.exs
  - config/runtime.exs
  - assets/js/app.js
  - assets/css/app.css
findings:
  critical: 0
  warning: 8
  info: 6
  total: 14
status: issues_found
---

# Phase 04: Code Review Report

**Reviewed:** 2026-04-16
**Depth:** standard
**Files Reviewed:** 34 source files (lib/, assets/, config/, mix.exs; HEEx layouts + ErrorHTML included)
**Status:** issues_found

## Summary

Phase 04 delivers the LiveView dashboard cleanly; the load-bearing security surfaces (slug regex, path validation, constant-time token compare, atomic frontmatter rewrite, audit-after-write ordering) are all present and correctly wired. The `Actions` module is the right chokepoint and it validates before writing — the architectural invariants ("Elixir is sole writer", "filesystem is source of truth", "audit log is append-only") hold at the implementation level I can see.

Findings below cluster in three areas:

1. **Defense-in-depth gaps at the LiveView mount layer.** LVs accept the `:company`, `:agent`, `:channel` URL params and use them directly in filesystem paths without re-running the slug regex that `Actions` enforces. `Actions` blocks malicious writes, but LV *reads* can still cross the `~/.glorbo/companies/<slug>/` boundary via `..`-style slugs (e.g. `/companies/../...`). Not a catastrophic escape (URL-segment matching forbids `%2F`) but it violates the "company isolation is absolute" invariant.
2. **Two HEEx rendering bugs in `ChannelLive`** — `#{@channel}` used inside a HEEx template where HEEx ignores `#{}` interpolation (should be `{@channel}`).
3. **`AuditLive` index-based expansion IDs** drift under filter/poll refresh, causing expanded-row flicker / wrong row staying expanded.

No Critical-severity findings (no injection, no secret leakage, no auth bypass, no data-loss path observed). The config fallback in `runtime.exs` derives `secret_key_base` from `$HOME` which is a Warning-severity weakness — deterministic low-entropy fallback rather than fail-closed.

## Warnings

### WR-01: HEEx interpolation bug — `#{@channel}` renders as literal text

**File:** `lib/glorbo_web/live/channel_live.ex:96,104`

**Issue:** Two locations use Elixir string interpolation (`#{...}`) inside a HEEx `~H` template. HEEx does NOT support `#{...}` — it uses `{...}` for assigns interpolation. Depending on HEEx version the output is either a compile error or literal text `#{@channel}` rendered verbatim. Every other reference in the same file (line 37, 45, 53, 116…) correctly uses `{@channel}`, so the shipped behavior is inconsistent.

```heex
<h1 class="gl-heading gl-heading--display">#{@channel}</h1>
...
<p>No messages in #{@channel} yet.</p>
```

**Fix:**

```heex
<h1 class="gl-heading gl-heading--display">#{<%= @channel %>}</h1>
<!-- or more idiomatically, if the `#` is literal: -->
<h1 class="gl-heading gl-heading--display">#{@channel}</h1>
```

Replace both with proper HEEx interpolation:

```heex
<h1 class="gl-heading gl-heading--display">#<%= @channel %></h1>
<!-- HEEx form: -->
<h1 class="gl-heading gl-heading--display">#{@channel}</h1>
```

Since HEEx disallows `#{}`, use the literal `#` followed by `{@channel}`:

```heex
<h1 class="gl-heading gl-heading--display"># {@channel}</h1>
<!-- or concatenate so the hash is adjacent: -->
<h1 class="gl-heading gl-heading--display">{"##{@channel}"}</h1>
```

The cleanest fix is to build the string in Elixir and interpolate once:

```heex
<h1 class="gl-heading gl-heading--display">{"##{@channel}"}</h1>
...
<p>{"No messages in ##{@channel} yet."}</p>
```

### WR-02: LiveView mounts do not validate slug shape before filesystem reads

**File:** `lib/glorbo_web/live/company_live.ex:20-24`, `kanban_live.ex:28-32`, `agent_live.ex:28-32`, `channel_live.ex:31-35`, `approval_queue_live.ex:27`, `audit_live.ex:26`

**Issue:** Every LV mount takes the `:company` (and often `:agent`, `:channel`) URL params, then passes them straight into `Path.join([base, "companies", slug, ...])` with a `File.dir?`/`File.read` check. The slug is never validated against the `~r/\A[a-z0-9-]+\z/` regex that `GlorboWeb.Actions` enforces at the write path.

Phoenix's path matcher already rejects URL-encoded slashes (`%2F`) because the `:company` placeholder only matches a single segment, so the classic `..%2F` escape fails. However, a literal `..` is still a valid URL path segment: `/companies/../agents/x` matches the route with `company = ".."`. `Path.join([base, "companies", ".."])` normalises to `base/companies/..` which `File.dir?` reports `true` for, and `load_agents` then lists `base/agents/` — outside the intended `companies/` scope.

Not a full sandbox escape (agents live under `companies/`, nothing interesting lives in `base/agents/`), and `Actions` blocks the corresponding writes, but this violates the "company isolation is absolute" invariant at the read layer and creates an avoidable side-channel: a malicious URL can probe which sibling directories exist under `~/.glorbo/`.

**Fix:** Add a slug gate to each LV `mount/3`. Easiest: extract the regex to a shared module (e.g. `GlorboWeb.Slug`) and call it before every filesystem-path construction:

```elixir
# lib/glorbo_web/slug.ex
defmodule GlorboWeb.Slug do
  @slug_re ~r/\A[a-z0-9-]+\z/
  def valid?(s) when is_binary(s), do: Regex.match?(@slug_re, s)
  def valid?(_), do: false
end

# in each LV mount/3, first thing:
def mount(%{"company" => co} = params, _session, socket) do
  agent = params["agent"]
  channel = params["channel"]

  if GlorboWeb.Slug.valid?(co) and
       (is_nil(agent) or GlorboWeb.Slug.valid?(agent)) and
       (is_nil(channel) or GlorboWeb.Slug.valid?(channel)) do
    # ...existing logic...
  else
    {:ok,
     socket
     |> put_flash(:error, "Invalid identifier.")
     |> push_navigate(to: ~p"/companies")}
  end
end
```

### WR-03: `AuditLive` row-expansion IDs collide across filter/poll refreshes

**File:** `lib/glorbo_web/live/audit_live.ex:140-145,74-83`

**Issue:** Expansion state is stored in a `MapSet` keyed by `"audit-#{idx}"` where `idx` comes from `Enum.with_index(@filtered)`. The index is re-computed every render from the *filtered* list. Two things break the mapping:

1. **Poll tick** (`:poll` every 1s) re-reads the file via `load_tail/2`; if a new row has appeared since the last render, every old row's index shifts by +1 and the `MapSet` now points at the wrong rows.
2. **Filter change** (`filter` event) alters `@filtered` length; every `MapSet` entry now addresses a different entry than the user clicked.

Result: a user expands row N, waits 1 s for a new audit event, and now row N–1 is expanded instead.

**Fix:** Key expansion on a stable field from the entry (audit payloads have a `ts` + `actor` + `action` tuple that is unique in practice; better, include a ULID/hash at write time). Minimal patch:

```elixir
# use a stable id derived from the entry
defp entry_id(entry, fallback_idx) do
  case entry do
    %{"ts" => ts, "actor" => a, "action" => act} -> "audit-#{ts}-#{a}-#{act}"
    _ -> "audit-#{fallback_idx}"
  end
end

# render:
<AuditEntry.audit_entry
  :for={{entry, idx} <- Enum.with_index(@filtered)}
  id={entry_id(entry, idx)}
  entry={entry}
  expanded={MapSet.member?(@expanded, entry_id(entry, idx))}
/>
```

### WR-04: Runtime config falls back to a deterministic `secret_key_base` derived from `$HOME`

**File:** `config/runtime.exs:47-53`

**Issue:** When `Glorbo.Config.load/0` fails, the endpoint still boots with:

```elixir
secret_key_base: :crypto.hash(:sha256, System.get_env("HOME", "/tmp")) |> Base.encode64()
```

This produces a 256-bit key derived from a single low-entropy, publicly-observable input. Anyone with shell access to the host (or who can guess the Director's `$HOME`) can recompute the endpoint's session-signing key and forge LiveView socket tokens / session cookies. For a loopback-only dev install this is mostly theoretical, but once `host: "0.0.0.0"` is set and the box has any other local user (multi-tenant VM, CI runner, shared workstation), it is a real auth bypass primitive.

Two mitigations are acceptable:

1. **Fail closed.** If `Glorbo.Config.load/0` returns `:error`, do NOT boot the endpoint; log a fatal error and halt. This matches the "filesystem is source of truth" invariant — if we can't read config.md, we shouldn't serve the dashboard with a degraded-security fallback.
2. **Generate an ephemeral random secret** (`:crypto.strong_rand_bytes(64) |> Base.encode64()`). Sessions die on restart, but entropy is adequate.

**Fix:**

```elixir
cfg =
  case Glorbo.Config.load() do
    {:ok, c} -> c
    {:error, _} ->
      # Fail closed on prod boot — don't degrade to a guessable secret.
      raise "Glorbo.Config.load/0 failed; refusing to boot with a weak fallback secret_key_base. Fix ~/.glorbo/config.md then restart."
  end
```

Or, if graceful boot is required for resilience, generate a fresh random key and log a `:error` level message so ops notice session invalidation.

### WR-05: `wake_agent` reason is unbounded and incompletely YAML-escaped

**File:** `lib/glorbo_web/actions.ex:132-153`

**Issue:** Two small problems in the same function:

1. **No length cap.** `GlorboWeb.AgentLive` sets `maxlength="200"` on the input client-side, but the LiveView channel delivers arbitrary payloads; a malicious client can submit a 100 MB reason string and `Actions.wake_agent/3` writes it verbatim. The `post_message/4` body path has a `@body_max_bytes` 10 KiB cap — `wake_agent` should share the same discipline.
2. **Incomplete YAML escaping.** `String.replace(reason, ~s("), ~s(\\"))` only escapes `"`. A reason containing `\n`, `\\`, or a leading `|`/`>` produces malformed frontmatter that `Frontmatter.parse/1` may reject or parse to an unexpected structure. `Glorbo.TaskDefinition.yaml_scalar/1` already solves this (quotes the string when ambiguous, escapes `"` and `\\`). Either reuse it or validate `reason` against a conservative charset.

**Fix:**

```elixir
@reason_max_bytes 1_024

def wake_agent(company, agent, reason, opts \\ []) do
  # ...
  reason = reason || ""

  with :ok <- validate_slug(company),
       :ok <- validate_slug(agent),
       :ok <- validate_reason(reason) do
    # ...
    body = """
    ---
    requested_at: "#{ts}"
    reason: #{yaml_scalar(reason)}
    ---

    Director wake request.
    """
    # ...
  end
end

defp validate_reason(r) when byte_size(r) > @reason_max_bytes,
  do: {:error, :reason_too_large}
defp validate_reason(r) when is_binary(r), do: :ok
defp validate_reason(_), do: {:error, :invalid_reason}

# Expose or duplicate TaskDefinition.yaml_scalar/1 locally.
```

### WR-06: `Actions.wake_agent/3` calls `mkdir_p!` before the write-try block

**File:** `lib/glorbo_web/actions.ex:140`

**Issue:** `File.mkdir_p!(dir)` will RAISE (not return `{:error, _}`) on permission/disk errors. This bypasses the function's documented `:ok | {:error, term()}` contract and crashes `AgentLive.handle_event("wake", ...)` under a permission failure, taking down the LiveView instead of surfacing the error as a flash message. By contrast `post_message/4` never calls `mkdir_p!` (it relies on pre-existing company skeleton).

Secondary issue: if `mkdir_p!` succeeds but `File.write` fails, the `state/` directory is now created as a side-effect without any state file landing — not corrupting, but surprising.

**Fix:**

```elixir
with :ok <- validate_slug(company),
     :ok <- validate_slug(agent),
     :ok <- validate_reason(reason),
     dir = Path.join([base, "companies", company, "agents", agent, "state"]),
     :ok <- File.mkdir_p(dir) do  # non-bang variant
  # ...
end
```

### WR-07: `assets/js/app.js` null-dereferences the CSRF meta tag

**File:** `assets/js/app.js:15`

**Issue:** `document.querySelector("meta[name='csrf-token']").getAttribute("content")` throws `TypeError: Cannot read properties of null` if the meta tag is missing (e.g., a future error page skips `root.html.heex`, or an adblocker/extension strips the element). The LiveSocket then never initializes and the whole dashboard is dead — with a confusing JS console error.

Not a bug today (root.html.heex always renders `<meta name="csrf-token">`), but it's fragile.

**Fix:**

```javascript
const csrfMeta = document.querySelector("meta[name='csrf-token']")
const csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : ""
if (!csrfToken) {
  console.error("glorbo: csrf-token meta missing; LiveSocket will fail CSRF check")
}
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}
})
liveSocket.connect()
window.liveSocket = liveSocket
```

### WR-08: Director action error messages leak low-level atoms to the UI

**File:** `lib/glorbo_web/live/channel_live.ex:85-88`, `agent_live.ex:109-110`, `approval_queue_live.ex:66-67,87-88`

**Issue:** Error paths use `inspect(err)` / `inspect(reason)` directly in flash text:

```elixir
{:error, err} ->
  {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(err)}")}
```

This leaks internal atoms (`:enoent`, `:eacces`, `:not_a_regular_file`, `{:path_outside_company, ...}`) into the UI. For the default loopback deployment this is fine (the Director owns the filesystem anyway), but once `dashboard_token` + `host: "0.0.0.0"` is set, `:eacces` vs `:enoent` distinguishable responses become a remote information-disclosure channel about the host filesystem layout.

**Fix:** Map error atoms to a fixed set of user-facing strings and log the raw reason separately:

```elixir
defp friendly_error(:empty_body), do: "Message is empty."
defp friendly_error(:body_too_large), do: "Message exceeds 10 KB."
defp friendly_error(:invalid_slug), do: "Invalid identifier."
defp friendly_error(:invalid_task_path), do: "Invalid task path."
defp friendly_error(:not_a_regular_file), do: "Channel file is not a regular file."
defp friendly_error(_), do: "Internal error. Check ~/.glorbo/logs/."

{:error, err} ->
  Logger.warning("post_message failed", reason: inspect(err))
  {:noreply, put_flash(socket, :error, friendly_error(err))}
```

## Info

### IN-01: `AuditLive.load_older/3` re-reads the whole JSONL on every click

**File:** `lib/glorbo_web/live/audit_live.ex:177-188`

**Issue:** Every "Load 500 older" click calls `File.read(path)` on the entire monthly audit file (potentially MB-scale) and then `String.split`. Also, `current_offset` comes from the previous `load_tail/2` call — if the file grew between the two reads (highly likely given the 1 s poll), the offset now points one or more rows too early, meaning the "older" page shows rows the user has already seen. A correct implementation would stash the last-loaded total, or key on byte offsets.

Performance is out of v1 review scope, but the stale-offset behavior is a correctness edge case worth noting.

**Fix:** Re-derive the offset from the entry `ts` of the top-most loaded row rather than from an index count, OR switch to line-by-line streaming (`File.stream!/1`).

### IN-02: `AgentLive` streamer-monitor race window

**File:** `lib/glorbo_web/live/agent_live.ex:49-52,84-92`

**Issue:** Classic OTP `start + monitor` race:

```elixir
case GlorboWeb.StdoutStreamer.start(co, ag, base: base) do
  {:ok, pid} ->
    Process.monitor(pid)   # if streamer crashed BEFORE this line, we miss :DOWN
```

If the streamer crashes after `start_child` returns `{:ok, pid}` but before `Process.monitor/1` registers, the LV never learns of the death and the `streamer_pid` is stale forever. Low probability since `init/1` is cheap, but easy to make race-free.

**Fix:** Use `DynamicSupervisor.start_child/2` with a monitor-at-start hook, or issue `Process.monitor/1` then re-check `Process.alive?/1` + probe with `:sys.get_status/1`:

```elixir
with {:ok, pid} <- GlorboWeb.StdoutStreamer.start(co, ag, base: base),
     ref <- Process.monitor(pid),
     true <- Process.alive?(pid) do
  {:ok, assign(socket, streamer_pid: pid, streamer_ref: ref)}
else
  _ ->
    # Already dead; treat as monitor-miss and re-spawn on next tick.
    Process.send_after(self(), :restart_streamer, 100)
    {:ok, socket}
end
```

### IN-03: Channel message parser is sensitive to `|` in author names

**File:** `lib/glorbo_web/live/channel_live.ex:28`

**Issue:** `@message_re = ~r/^## (?<ts>[^|]+?)\s*\|\s*(?<author>.+?)\s*\n.../` uses `|` as the ts/author separator. `post_message/4` is the sole writer and always produces `## <iso_ts> | Director\n`, so no production content breaks. But if Phase 3 agents start writing inbox/outbox messages into channels (or the spec evolves), an author or ts containing `|` would cause the regex to misattribute fields.

**Fix:** Either (a) document that `|` is reserved and add a writer-side validator in `Actions.post_message/4`, or (b) switch to a format with an unambiguous delimiter (e.g. JSONL adjacent to the channel md, or `## <ts> · <author>` with a middle-dot that won't appear in slugs).

### IN-04: `post_message/4` does not validate body is valid UTF-8

**File:** `lib/glorbo_web/actions.ex:62-90`

**Issue:** `validate_body/1` checks emptiness and byte size but accepts any binary. Binary-but-not-UTF-8 content writes cleanly to disk but `Regex.scan(@message_re, content)` in `ChannelLive.parse_messages/2` will crash on invalid UTF-8, bricking the channel view until the offending message is manually removed from `channels/<ch>.md`.

**Fix:**

```elixir
defp validate_body(b) when is_binary(b) and byte_size(b) > @body_max_bytes,
  do: {:error, :body_too_large}

defp validate_body(b) when is_binary(b) do
  if String.valid?(b), do: :ok, else: {:error, :invalid_utf8}
end
```

### IN-05: `CompanyLive` renders a static "Kanban active" tab regardless of the actual active route

**File:** `lib/glorbo_web/live/company_live.ex:68-98`

**Issue:** The tab bar is a bespoke inline block (not the shared `TabBar` component — which `TabBar.ex` even calls out as "CompanyLive currently renders its own inline tab markup"). The `gl-tab--active` class is hard-coded on the Kanban link. When a user lands on `/companies/:co` and clicks "Audit", navigation works but the tab bar is gone (AuditLive/ChannelLive/ApprovalQueueLive don't render one). Orientation within a company is lost after the first click.

Not a functional bug — all navigation still works via the sidebar — but the `TabBar` component was built for exactly this use case and is unused.

**Fix:** Either (a) adopt the shared `TabBar.tab_bar/1` component across CompanyLive, KanbanLive, ChannelLive, ApprovalQueueLive, AuditLive with correct `active?` flags per route, or (b) delete `TabBar` if it's truly dead code. Since review scope excludes UX, this is informational only.

### IN-06: `HealthLive.summarize_child/1` reports every child as `status: :healthy` unconditionally

**File:** `lib/glorbo_web/live/health_live.ex:143-154`

**Issue:**

```elixir
defp summarize_child({_id, pid, _type, _mods}) do
  # ...
  %{name: inspect(pid), status: :healthy, child_count: length(children)}
end
```

A `:restarting` / `:undefined` pid from `Supervisor.which_children/1` would still be labeled `:healthy`. The semantic intent of HealthLive's dot is "is this supervisor up?" — but the code never checks. Also, `name: inspect(pid)` renders `#PID<0.234.0>` to the user, which is not informative (the Company slug would be).

**Fix:**

```elixir
defp summarize_child({id, pid, _type, _mods}) do
  status =
    case pid do
      pid when is_pid(pid) -> if Process.alive?(pid), do: :healthy, else: :crashed
      :restarting -> :warning
      :undefined -> :crashed
    end

  children =
    if is_pid(pid), do: safe_which_children(pid), else: []

  %{name: to_string(id), status: status, child_count: length(children)}
end
```

---

_Reviewed: 2026-04-16_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
