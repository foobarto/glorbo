defmodule Glorbo.Agent.PermissionMountSummaryTest do
  @moduledoc """
  Regression test for the `permission_mount_summary/1` helper in
  `Glorbo.Agent.Server` — the bullet list that tells agents which
  paths their sandbox exposes beyond `/workspace`, `/inbox`, `/outbox`.

  E2E benchmark (`.reports/uat-v3-live/e2e-delivery.md`) surfaced that
  without this, the editor's qwen3.6 model looked in `/workspace/**`
  for a draft that actually lived at `/projects/blog/tasks/`. Ship
  regression coverage so the prompt can't silently lose this block.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Server

  defp spec(permissions) do
    %Glorbo.Agent.Spec{
      slug: "t",
      company: "co",
      role: "test",
      provider: "opencode",
      model: "m",
      permissions: permissions,
      heartbeat: nil,
      network: :proxy,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 300,
      file_path: "/tmp/t.md"
    }
  end

  test "projects:read:* renders a read-all bullet" do
    out = Server.permission_mount_summary(spec([{"projects", "read", "*"}]))
    assert out =~ "`/projects/` (ro)"
    assert out =~ "all projects"
  end

  test "projects:write:<name> scopes to that project only" do
    out = Server.permission_mount_summary(spec([{"projects", "write", "blog"}]))
    assert out =~ "`/projects/blog/` (rw)"
    assert out =~ "only this project writable"
  end

  test "multiple permissions render as multiple bullets" do
    out =
      Server.permission_mount_summary(
        spec([
          {"projects", "read", "*"},
          {"projects", "write", "blog"},
          {"chat", "read", "*"}
        ])
      )

    assert out =~ "`/projects/` (ro)"
    assert out =~ "`/projects/blog/` (rw)"
    assert out =~ "`/chat/` (ro)"
    # Bullets are one per line.
    assert out |> String.split("\n") |> length() == 3
  end

  test "no permissions → explicit empty-state copy" do
    out = Server.permission_mount_summary(spec([]))
    assert out =~ "(none"
    assert out =~ "/workspace"
    assert out =~ "/outbox"
  end

  test "unknown resource:action tuples are dropped silently" do
    # Forward-compat: parser may introduce new {resource, action, scope}
    # combinations before Server.permission_to_bullet/1 learns about
    # them. Silent drop is better than a crash.
    out =
      Server.permission_mount_summary(
        spec([
          {"projects", "read", "*"},
          {"future_feature", "read", "x"}
        ])
      )

    assert out =~ "`/projects/` (ro)"
    refute out =~ "future_feature"
  end
end
