defmodule Glorbo.CLI.ImportPaperclipTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.ImportPaperclip

  setup do
    home = Path.join(System.tmp_dir!(), "glorbo_paperclip_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("GLORBO_HOME", home)

    on_exit(fn ->
      System.delete_env("GLORBO_HOME")
      File.rm_rf!(home)
    end)

    src = Path.join(home, "paperclip-src")
    File.mkdir_p!(src)
    {:ok, home: home, src: src}
  end

  defp seed_paperclip_agent(src, slug, files) do
    dir = Path.join(src, slug)
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)
    dir
  end

  describe "run/1 argv handling" do
    test "no args prints usage and exits 1" do
      assert {:import_paperclip, 1, out} = ImportPaperclip.run([])
      assert out =~ "Usage:"
    end

    test "--help prints help" do
      assert {:import_paperclip, 0, out} = ImportPaperclip.run(["--help"])
      assert out =~ "import a paperclip.ai"
    end

    test "missing source dir returns error", %{home: home} do
      missing = Path.join(home, "does-not-exist")
      assert {:import_paperclip, 1, out} = ImportPaperclip.run([missing])
      assert out =~ "Not a directory"
    end
  end

  describe "import/scaffold" do
    test "imports a single-agent paperclip tree and creates Glorbo layout", %{
      src: src,
      home: home
    } do
      seed_paperclip_agent(src, "ceo", %{
        "AGENTS.md" => "You are the CEO of AcmeCo.\n\nUse $AGENT_HOME for memory.\n",
        "HEARTBEAT.md" => "# CEO heartbeat\n\n1. GET /api/agents/me\n",
        "SOUL.md" => "Direct. Pragmatic.\n",
        "TOOLS.md" => "- paperclip-create-agent\n"
      })

      assert {:import_paperclip, 0, out} =
               ImportPaperclip.run([src, "--as", "acmeco"])

      co = Path.join([home, "companies", "acmeco"])
      assert File.dir?(co)
      assert File.exists?(Path.join(co, "company.md"))

      agent_dir = Path.join([co, "agents", "ceo"])
      assert File.dir?(agent_dir)
      assert File.exists?(Path.join(agent_dir, "AGENT.md"))
      assert File.exists?(Path.join(agent_dir, "HEARTBEAT.md"))
      assert File.exists?(Path.join(agent_dir, "SOUL.md"))
      assert File.exists?(Path.join(agent_dir, "TOOLS.md"))

      # Agent AGENT.md wraps paperclip body with Glorbo frontmatter.
      agent_md = File.read!(Path.join(agent_dir, "AGENT.md"))
      assert agent_md =~ ~r/^---\n/
      assert agent_md =~ "imported_from: paperclip"
      assert agent_md =~ "imported_company: acmeco"
      assert agent_md =~ "You are the CEO of AcmeCo."

      # Paperclip body preserved verbatim (including $AGENT_HOME).
      assert agent_md =~ "$AGENT_HOME"

      # Report surfaces hints for HTTP API + paperclip skill + $AGENT_HOME.
      assert out =~ "imported paperclip company"
      assert out =~ "Review the following paperclip-isms"
      assert out =~ "$AGENT_HOME"
    end

    test "default slug comes from src basename", %{home: home} do
      src = Path.join(home, "mycompany")
      File.mkdir_p!(src)

      seed_paperclip_agent(src, "ceo", %{"AGENTS.md" => "hi\n"})

      assert {:import_paperclip, 0, _out} = ImportPaperclip.run([src])
      assert File.dir?(Path.join([home, "companies", "mycompany"]))
    end

    test "refuses to overwrite existing company without --force", %{src: src, home: home} do
      seed_paperclip_agent(src, "ceo", %{"AGENTS.md" => "hi\n"})

      assert {:import_paperclip, 0, _} = ImportPaperclip.run([src, "--as", "acme2"])

      assert {:import_paperclip, 1, out} = ImportPaperclip.run([src, "--as", "acme2"])
      assert out =~ "Target exists"
      assert out =~ "--force"

      # Target unchanged, not duplicated.
      assert File.dir?(Path.join([home, "companies", "acme2"]))
    end

    test "--force overwrites on re-import", %{src: src, home: home} do
      seed_paperclip_agent(src, "ceo", %{"AGENTS.md" => "first\n"})
      assert {:import_paperclip, 0, _} = ImportPaperclip.run([src, "--as", "acme3"])

      # Update source, re-import with --force.
      File.write!(Path.join([src, "ceo", "AGENTS.md"]), "second\n")
      assert {:import_paperclip, 0, _} = ImportPaperclip.run([src, "--as", "acme3", "--force"])

      body = File.read!(Path.join([home, "companies", "acme3", "agents", "ceo", "AGENT.md"]))
      assert body =~ "second"
      refute body =~ "first"
    end

    test "skips directories that don't have AGENTS.md", %{src: src, home: home} do
      # Agent-looking dir (has AGENTS.md)
      seed_paperclip_agent(src, "ceo", %{"AGENTS.md" => "ok\n"})
      # Non-agent dir (no AGENTS.md)
      File.mkdir_p!(Path.join(src, "templates"))
      File.write!(Path.join([src, "templates", "stuff.md"]), "not an agent\n")

      assert {:import_paperclip, 0, out} = ImportPaperclip.run([src, "--as", "acme4"])
      assert out =~ "agents: 1"
      refute out =~ "templates"

      refute File.dir?(Path.join([home, "companies", "acme4", "agents", "templates"]))
    end

    test "invalid slug returns error before scaffolding", %{src: src, home: home} do
      seed_paperclip_agent(src, "ceo", %{"AGENTS.md" => "ok\n"})

      assert {:import_paperclip, 1, out} = ImportPaperclip.run([src, "--as", "Invalid Slug"])
      assert out =~ "Invalid slug"
      refute File.exists?(Path.join([home, "companies", "Invalid Slug"]))
    end
  end
end
