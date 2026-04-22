defmodule Glorbo.Skills.ResolverTest do
  use ExUnit.Case, async: true

  alias Glorbo.Skills.Resolver
  alias Glorbo.Test.TmpGlorboHome

  setup do
    base = TmpGlorboHome.setup()
    skills_dir = Path.join(base, "skills")
    File.mkdir_p!(skills_dir)
    target = Path.join([base, "run", "t1", ".glorbo-skills"])
    {:ok, base: base, skills_dir: skills_dir, target: target}
  end

  defp write_skill(ctx, name, content) do
    File.write!(Path.join(ctx.skills_dir, "#{name}.md"), content)
  end

  defp collect_audit do
    pid = self()
    fn _company, entry -> send(pid, {:audit, entry}) end
  end

  # ---------------------------------------------------------------------------
  # S1, S2 — full materialisation + INDEX.md
  # ---------------------------------------------------------------------------

  test "S1+S2: both skills materialised with INDEX listing titles in input order", ctx do
    write_skill(ctx, "skill-a", "# Title line A\n\nBody\n")
    write_skill(ctx, "skill-b", "# Title line B\n\nBody\n")

    assert {:ok, ["skill-a", "skill-b"]} =
             Resolver.materialize(["skill-a", "skill-b"], ctx.target, base: ctx.base)

    assert File.exists?(Path.join(ctx.target, "skill-a.md"))
    assert File.exists?(Path.join(ctx.target, "skill-b.md"))

    index = File.read!(Path.join(ctx.target, "INDEX.md"))
    assert index =~ "- [skill-a](./skill-a.md) — Title line A"
    assert index =~ "- [skill-b](./skill-b.md) — Title line B"

    # Order matches input (D-40)
    a_pos = :binary.match(index, "skill-a") |> elem(0)
    b_pos = :binary.match(index, "skill-b") |> elem(0)
    assert a_pos < b_pos
  end

  # ---------------------------------------------------------------------------
  # Builtin fallback — a skill not in the per-instance dir still
  # resolves if `priv/templates/skills/<name>.md` ships it. Applied
  # for the `glorbo` skill in PLAN P2-4 so every agent has the
  # runtime contract available without manual scaffolding.
  # ---------------------------------------------------------------------------

  test "resolves a builtin skill from priv/templates/skills/ when user dir lacks it", ctx do
    # `glorbo` isn't in ctx.skills_dir but ships under priv/.
    assert {:ok, ["glorbo"]} = Resolver.materialize(["glorbo"], ctx.target, base: ctx.base)
    assert File.exists?(Path.join(ctx.target, "glorbo.md"))

    index = File.read!(Path.join(ctx.target, "INDEX.md"))
    assert index =~ "glorbo"
  end

  test "per-instance skill shadows the builtin when both exist", ctx do
    # User-defined `glorbo.md` takes precedence over the bundled one.
    write_skill(ctx, "glorbo", "# Custom glorbo title\n\nbody\n")

    assert {:ok, ["glorbo"]} = Resolver.materialize(["glorbo"], ctx.target, base: ctx.base)

    copied = File.read!(Path.join(ctx.target, "glorbo.md"))
    assert copied =~ "Custom glorbo title"
  end

  test "symlinked user shadow is ignored in favor of a regular builtin", ctx do
    external = Path.join(ctx.base, "external-secret.md")
    File.write!(external, "# Secret shadow\n\nleak\n")
    File.ln_s!(external, Path.join(ctx.skills_dir, "glorbo.md"))

    assert {:ok, ["glorbo"]} = Resolver.materialize(["glorbo"], ctx.target, base: ctx.base)

    copied = File.read!(Path.join(ctx.target, "glorbo.md"))
    refute copied =~ "Secret shadow"
  end

  # ---------------------------------------------------------------------------
  # S3 — single missing skill emits audit, returns empty list
  # ---------------------------------------------------------------------------

  test "S3: missing skill emits skill.missing audit and returns {:ok, []}", ctx do
    audit_fun = collect_audit()

    assert {:ok, []} =
             Resolver.materialize(["missing-skill"], ctx.target, [
               {:base, ctx.base},
               {:company, "acme"},
               {:agent_slug, "engineer"},
               {:audit_fun, audit_fun}
             ])

    assert_received {:audit, %{action: "skill.missing", skill_name: "missing-skill"}}
  end

  # ---------------------------------------------------------------------------
  # S4 — mixed: present, missing, present
  # ---------------------------------------------------------------------------

  test "S4: mixed present/missing/present resolves 2 skills and emits one audit", ctx do
    write_skill(ctx, "skill-a", "# A\nBody\n")
    write_skill(ctx, "skill-b", "# B\nBody\n")

    audit_fun = collect_audit()

    assert {:ok, resolved} =
             Resolver.materialize(["skill-a", "missing", "skill-b"], ctx.target, [
               {:base, ctx.base},
               {:audit_fun, audit_fun}
             ])

    assert resolved == ["skill-a", "skill-b"]

    index = File.read!(Path.join(ctx.target, "INDEX.md"))
    refute index =~ "missing"
    assert index =~ "skill-a"
    assert index =~ "skill-b"

    assert_received {:audit, %{action: "skill.missing", skill_name: "missing"}}
    refute_received {:audit, %{action: "skill.missing"}}
  end

  test "symlinked custom skill is treated as missing and audited", ctx do
    external = Path.join(ctx.base, "external-secret.md")
    File.write!(external, "# Secret shadow\n\nleak\n")
    File.ln_s!(external, Path.join(ctx.skills_dir, "linked-skill.md"))

    audit_fun = collect_audit()

    assert {:ok, []} =
             Resolver.materialize(["linked-skill"], ctx.target, [
               {:base, ctx.base},
               {:company, "acme"},
               {:agent_slug, "engineer"},
               {:audit_fun, audit_fun}
             ])

    assert_received {:audit, %{action: "skill.missing", skill_name: "linked-skill"}}
    refute File.exists?(Path.join(ctx.target, "linked-skill.md"))
  end

  # ---------------------------------------------------------------------------
  # S5 — empty skills list: create dir, no INDEX.md
  # ---------------------------------------------------------------------------

  test "S5: empty skills list creates target_dir but no INDEX.md", ctx do
    assert {:ok, []} = Resolver.materialize([], ctx.target, base: ctx.base)
    assert File.dir?(ctx.target)
    refute File.exists?(Path.join(ctx.target, "INDEX.md"))
  end

  # ---------------------------------------------------------------------------
  # S6 — path traversal rejected at entry without any IO
  # ---------------------------------------------------------------------------

  test "S6: path traversal rejected without touching filesystem (T-03-19)", ctx do
    assert {:error, {:invalid_skill_name, "../../../etc/passwd"}} =
             Resolver.materialize(["../../../etc/passwd"], ctx.target, base: ctx.base)

    refute File.exists?(ctx.target)
  end

  # ---------------------------------------------------------------------------
  # S7 — cleanup on non-existent dir returns :ok
  # ---------------------------------------------------------------------------

  test "S7: cleanup/1 on non-existent directory returns :ok (idempotent)", _ctx do
    assert :ok = Resolver.cleanup("/tmp/glorbo_nonexistent_#{System.unique_integer([:positive])}")
  end

  # ---------------------------------------------------------------------------
  # S7b — cleanup removes an existing directory tree
  # ---------------------------------------------------------------------------

  test "cleanup/1 removes an existing directory tree recursively", ctx do
    sub = Path.join(ctx.target, "inner")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "x.md"), "hello")

    assert :ok = Resolver.cleanup(ctx.target)
    refute File.exists?(ctx.target)
  end

  # ---------------------------------------------------------------------------
  # S8 — cleanup does not follow symlinks (File.rm_rf is safe)
  # ---------------------------------------------------------------------------

  test "S8: cleanup does not follow symlinks", ctx do
    # Create a safe external target we do NOT want deleted
    external = Path.join(ctx.base, "external_target")
    File.mkdir_p!(external)
    File.write!(Path.join(external, "keep-me.txt"), "do not touch")

    # Set up run_dir with a symlink to external
    File.mkdir_p!(ctx.target)
    link = Path.join(ctx.target, "symlink_to_ext")
    File.ln_s!(external, link)

    assert :ok = Resolver.cleanup(ctx.target)

    refute File.exists?(ctx.target)
    # External target must be preserved
    assert File.exists?(Path.join(external, "keep-me.txt"))
  end

  # ---------------------------------------------------------------------------
  # Fallback title behaviour (non-# first line)
  # ---------------------------------------------------------------------------

  test "INDEX.md falls back to skill name when first line is not a heading", ctx do
    write_skill(ctx, "plain", "Some plain text\n")

    assert {:ok, ["plain"]} = Resolver.materialize(["plain"], ctx.target, base: ctx.base)

    index = File.read!(Path.join(ctx.target, "INDEX.md"))
    assert index =~ "- [plain](./plain.md) — plain"
  end
end
