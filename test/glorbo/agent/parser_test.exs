defmodule Glorbo.Agent.ParserTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Parser
  alias Glorbo.Agent.Spec
  alias Glorbo.Test.TmpGlorboHome

  setup do
    base = TmpGlorboHome.setup()
    company_dir = Path.join([base, "companies", "acme"])
    agents_dir = Path.join(company_dir, "agents")
    File.mkdir_p!(agents_dir)
    {:ok, base: base, agents_dir: agents_dir}
  end

  defp agent_dir(ctx, slug) do
    dir = Path.join(ctx.agents_dir, slug)
    File.mkdir_p!(dir)
    dir
  end

  defp write_agent(ctx, slug, content) do
    dir = agent_dir(ctx, slug)
    path = Path.join(dir, "AGENT.md")
    File.write!(path, content)
    path
  end

  # ---------------------------------------------------------------------------
  # P1 — valid agent.md → fully-populated Spec
  # ---------------------------------------------------------------------------

  describe "parse_file/1 success" do
    test "P1: valid agent.md returns fully populated Spec", ctx do
      content = """
      ---
      role: Senior Engineer
      provider: claude-code
      model: claude-opus-4-6
      permissions:
        - projects:write:website-redesign
        - chat:read:*
      heartbeat: "*/30 * * * *"
      network: api-only
      skills:
        - elixir-style
        - git-hygiene
      budget_usd_cents_month: 10000
      timeout_seconds: 600
      ---
      # engineer — main responsibilities
      """

      path = write_agent(ctx, "engineer", content)

      assert {:ok, %Spec{} = spec} = Parser.parse_file(path)
      assert spec.slug == "engineer"
      assert spec.company == "acme"
      assert spec.role == "Senior Engineer"
      assert spec.provider == "claude-code"
      assert spec.model == "claude-opus-4-6"

      assert {"projects", "write", "website-redesign"} in spec.permissions
      assert {"chat", "read", "*"} in spec.permissions
      assert spec.heartbeat == "*/30 * * * *"
      assert spec.network == :api_only
      assert spec.skills == ["elixir-style", "git-hygiene"]
      assert spec.budget_usd_cents_month == 10_000
      assert spec.timeout_seconds == 600
      assert spec.file_path == path
    end
  end

  # ---------------------------------------------------------------------------
  # P2..P6 — field-level rejections
  # ---------------------------------------------------------------------------

  describe "provider validation (D-02 P2, P15)" do
    test "P2: unknown provider rejected with {:invalid_provider, _}", ctx do
      content = """
      ---
      role: x
      provider: bogus-provider
      model: some-model
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:error, {:invalid_provider, "bogus-provider"}} = Parser.parse_file(path)
    end

    test "provider missing → {:invalid_provider, \"\"}", ctx do
      content = """
      ---
      role: x
      model: some-model
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:error, {:invalid_provider, ""}} = Parser.parse_file(path)
    end
  end

  describe "model validation (LLM-04 P3, P4)" do
    test "P3: missing model returns :missing_model", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:error, :missing_model} = Parser.parse_file(path)
    end

    test "P4: list model returns :multiple_models_not_supported", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model:
        - claude-opus-4-6
        - claude-sonnet-4-5
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:error, :multiple_models_not_supported} = Parser.parse_file(path)
    end
  end

  describe "permission validation (P5, P6)" do
    test "P5: malformed permission tuple is rejected", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      permissions:
        - projects:bogus
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:error, {:invalid_permission, "projects:bogus"}} = Parser.parse_file(path)
    end

    test "P6: unknown resource rejected via ACLMapper", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      permissions:
        - unknown:write:foo
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:error, {:invalid_permission, "unknown:write:foo"}} = Parser.parse_file(path)
    end

    test "P7: missing permissions field defaults to []", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:ok, spec} = Parser.parse_file(path)
      assert spec.permissions == []
    end
  end

  # ---------------------------------------------------------------------------
  # Network policy (P8, P9)
  # ---------------------------------------------------------------------------

  describe "network validation (P8, P9)" do
    test "P8a: network: none → :none", ctx do
      content = ~s"""
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      network: none
      ---
      """

      path = write_agent(ctx, "a", content)
      assert {:ok, %{network: :none}} = Parser.parse_file(path)
    end

    test "P8b: network: api-only → :api_only", ctx do
      content = ~s"""
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      network: api-only
      ---
      """

      path = write_agent(ctx, "b", content)
      assert {:ok, %{network: :api_only}} = Parser.parse_file(path)
    end

    test "P8c: network: open → :open", ctx do
      content = ~s"""
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      network: open
      ---
      """

      path = write_agent(ctx, "c", content)
      assert {:ok, %{network: :open}} = Parser.parse_file(path)
    end

    test "P8d: unknown network → {:invalid_network, _}", ctx do
      content = ~s"""
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      network: bogus
      ---
      """

      path = write_agent(ctx, "d", content)
      assert {:error, {:invalid_network, "bogus"}} = Parser.parse_file(path)
    end

    test "P9: missing network defaults to :api_only (CLI providers need egress)", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      ---
      """

      path = write_agent(ctx, "e", content)
      assert {:ok, %{network: :api_only}} = Parser.parse_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # Heartbeat + budget + timeout defaults (P10, P11, P12)
  # ---------------------------------------------------------------------------

  describe "defaults (P10, P11, P12)" do
    test "P10: missing heartbeat defaults to nil", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      ---
      """

      path = write_agent(ctx, "f", content)
      assert {:ok, %{heartbeat: nil}} = Parser.parse_file(path)
    end

    test "P11: missing budget defaults to nil (no hard-stop)", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      ---
      """

      path = write_agent(ctx, "g", content)
      assert {:ok, %{budget_usd_cents_month: nil}} = Parser.parse_file(path)
    end

    test "P12: missing timeout_seconds defaults to 300 (D-06)", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      ---
      """

      path = write_agent(ctx, "h", content)
      assert {:ok, %{timeout_seconds: 300}} = Parser.parse_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # Skills normalisation (P13, P14)
  # ---------------------------------------------------------------------------

  describe "skills validation (P13, P14)" do
    test "P13: scalar skill string normalises to single-element list", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      skills: elixir-style
      ---
      """

      path = write_agent(ctx, "i", content)
      assert {:ok, %{skills: ["elixir-style"]}} = Parser.parse_file(path)
    end

    test "P14: skill name with ../ rejected (T-03-19 path traversal)", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      skills:
        - ../evil
      ---
      """

      path = write_agent(ctx, "j", content)
      assert {:error, {:invalid_skill_name, "../evil"}} = Parser.parse_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # AGT-05 defence-in-depth (P15)
  # ---------------------------------------------------------------------------

  describe "AGT-05 agents:create block (P15)" do
    test "P15: declaring agents:create:* returns :agents_create_forbidden", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      permissions:
        - agents:create:*
      ---
      """

      path = write_agent(ctx, "k", content)
      assert {:error, :agents_create_forbidden} = Parser.parse_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # Slug derivation + regex validation (P16)
  # ---------------------------------------------------------------------------

  describe "slug derivation (P16)" do
    test "P16: slug derived from file path", ctx do
      content = """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      ---
      """

      path = write_agent(ctx, "engineer", content)
      assert {:ok, %{slug: "engineer"}} = Parser.parse_file(path)
    end

    test "P16: invalid slug from path rejected", ctx do
      # "UPPER" is not a valid kebab-case slug — begins with a capital letter
      # (which the regex forbids because it requires `[a-z]` start).
      dir = Path.join(ctx.agents_dir, "UPPER")
      File.mkdir_p!(dir)
      path = Path.join(dir, "AGENT.md")

      File.write!(path, """
      ---
      role: x
      provider: claude-code
      model: claude-opus-4-6
      ---
      """)

      assert {:error, {:invalid_slug, "UPPER"}} = Parser.parse_file(path)
    end

    test "P17: FontAwesome icon normalises to `fa-<name>`", ctx do
      for {raw, expected} <- [
            {"fa-rocket", "fa-rocket"},
            {"rocket", "fa-rocket"},
            {"FA-User-Tie", "fa-user-tie"},
            {"fa-arrow-up-right-from-square", "fa-arrow-up-right-from-square"},
            # Invalid — rejected, icon: nil (not an error).
            {"<script>", nil},
            {"fa-rocket; rm -rf /", nil},
            {"", nil}
          ] do
        path =
          write_agent(ctx, "eng-#{:erlang.phash2(raw)}", ~s"""
          ---
          role: x
          provider: claude-code
          model: claude-opus-4-6
          icon: "#{raw}"
          ---
          """)

        assert {:ok, spec} = Parser.parse_file(path)
        assert spec.icon == expected, "for input #{inspect(raw)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # IO errors
  # ---------------------------------------------------------------------------

  test "parse_file/1 on non-existent path returns {:read_error, _}" do
    assert {:error, {:read_error, :enoent}} = Parser.parse_file("/nonexistent/agent.md")
  end
end
