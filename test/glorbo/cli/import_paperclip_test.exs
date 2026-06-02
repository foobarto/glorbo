defmodule Glorbo.CLI.ImportPaperclipTest do
  # `async: false` — setup mutates the process-global `GLORBO_HOME`
  # env var and multiple async tests racing on it cause flakes like
  # "target path doesn't exist after scaffold" when another test's
  # on_exit clobbers the var mid-run. Keeping per-test isolation via
  # the unique-integer home dir; serializing the test module is the
  # cheapest fix that doesn't require restructuring the scaffold to
  # take base as an argument everywhere.
  use ExUnit.Case, async: false

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

  # GEP-54: live paperclip-instance layout — agents live at
  # <src>/agents/<uuid>/instructions/AGENTS.md (one level deeper, with
  # companion files inside instructions/). Returns the agent dir.
  defp seed_instance_agent(src, uuid, files) do
    instr = Path.join([src, "agents", uuid, "instructions"])
    File.mkdir_p!(instr)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(instr, name), body) end)
    Path.join([src, "agents", uuid])
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

  describe "instance layout (GEP-54)" do
    @ceo_uuid "a9722683-6e12-4a31-921f-9b5a5ef6aa2d"
    @writer_uuid "f2e45260-ee53-44ad-8912-1dbe21659fe7"

    test "imports agents nested under agents/<uuid>/instructions/", %{src: src, home: home} do
      seed_instance_agent(src, @ceo_uuid, %{
        "AGENTS.md" => "You are the CEO.\n\nUse $AGENT_HOME for memory.\n",
        "HEARTBEAT.md" => "# CEO heartbeat\n",
        "SOUL.md" => "Direct.\n",
        "TOOLS.md" => "- paperclip-create-agent\n"
      })

      seed_instance_agent(src, @writer_uuid, %{
        "AGENTS.md" => "You are Riven March.\n"
      })

      assert {:import_paperclip, 0, out} = ImportPaperclip.run([src, "--as", "blade"])

      co = Path.join([home, "companies", "blade"])
      assert File.dir?(co)
      assert out =~ "agents: 2"

      # Agents imported under their UUID dir names (no slug derivation).
      ceo = Path.join([co, "agents", @ceo_uuid])
      assert File.dir?(ceo)
      agent_md = File.read!(Path.join(ceo, "AGENT.md"))
      assert agent_md =~ ~r/^---\n/
      assert agent_md =~ "imported_from: paperclip"
      assert agent_md =~ "imported_company: blade"
      assert agent_md =~ "You are the CEO."

      # Companion files copied from instructions/ into the agent root.
      assert File.exists?(Path.join(ceo, "HEARTBEAT.md"))
      assert File.exists?(Path.join(ceo, "SOUL.md"))
      assert File.exists?(Path.join(ceo, "TOOLS.md"))

      assert File.exists?(Path.join([co, "agents", @writer_uuid, "AGENT.md"]))
    end

    test "excludes _templates and other _-prefixed dirs", %{src: src, home: home} do
      seed_instance_agent(src, @ceo_uuid, %{"AGENTS.md" => "You are the CEO.\n"})

      # Paperclip ships a _templates/base-bundle scaffold under agents/.
      tmpl = Path.join([src, "agents", "_templates", "base-bundle"])
      File.mkdir_p!(tmpl)
      File.write!(Path.join(tmpl, "AGENTS.md"), "You are <ROLE NAME>.\n")

      assert {:import_paperclip, 0, out} = ImportPaperclip.run([src, "--as", "blade2"])
      assert out =~ "agents: 1"
      refute File.dir?(Path.join([home, "companies", "blade2", "agents", "_templates"]))
    end

    test "does not carry memory/ but notes it in the report", %{src: src, home: home} do
      agent_dir = seed_instance_agent(src, @ceo_uuid, %{"AGENTS.md" => "You are the CEO.\n"})
      File.mkdir_p!(Path.join(agent_dir, "memory"))
      File.write!(Path.join([agent_dir, "memory", "2026-04-14.md"]), "old note\n")

      assert {:import_paperclip, 0, out} = ImportPaperclip.run([src, "--as", "blade3"])

      refute File.dir?(Path.join([home, "companies", "blade3", "agents", @ceo_uuid, "memory"]))
      assert out =~ "memory"
    end

    test "reports loudly when zero agents match", %{src: src} do
      # An agents/ container that holds only a non-agent dir.
      File.mkdir_p!(Path.join([src, "agents", "_templates"]))

      assert {:import_paperclip, 0, out} = ImportPaperclip.run([src, "--as", "empty1"])
      assert out =~ "agents: 0"
      assert out =~ "0 agents"
    end

    test "a flat agent literally named `agents` is not mistaken for an instance container",
         %{src: src, home: home} do
      seed_paperclip_agent(src, "agents", %{"AGENTS.md" => "You are the ops bot.\n"})
      seed_paperclip_agent(src, "ceo", %{"AGENTS.md" => "You are the CEO.\n"})

      assert {:import_paperclip, 0, out} = ImportPaperclip.run([src, "--as", "flat1"])
      assert out =~ "agents: 2"
      assert File.exists?(Path.join([home, "companies", "flat1", "agents", "agents", "AGENT.md"]))
      assert File.exists?(Path.join([home, "companies", "flat1", "agents", "ceo", "AGENT.md"]))
    end

    test "refuses a symlinked instructions/AGENTS.md (deep C-098)", %{src: src, home: home} do
      secret = Path.join(home, "deep-secret.txt")
      File.write!(secret, "SSH PRIVATE KEY MATERIAL\n")

      instr = Path.join([src, "agents", @ceo_uuid, "instructions"])
      File.mkdir_p!(instr)
      File.ln_s!(secret, Path.join(instr, "AGENTS.md"))

      assert {:import_paperclip, code, out} = ImportPaperclip.run([src, "--as", "victim3"])

      agent_md = Path.join([home, "companies", "victim3", "agents", @ceo_uuid, "AGENT.md"])
      refute File.exists?(agent_md)
      assert code in [0, 1]
      refute out =~ "SSH PRIVATE KEY"
    end
  end

  describe "symlink hardening (C-098)" do
    # A symlinked AGENTS.md -> host secret must NOT be discovered as an
    # agent (lstat refuses the non-regular file), so its contents never
    # land in company data.
    test "does not import an agent whose AGENTS.md is a symlink", %{src: src, home: home} do
      secret = Path.join(home, "secret.txt")
      File.write!(secret, "SSH PRIVATE KEY MATERIAL\n")

      dir = Path.join(src, "evil")
      File.mkdir_p!(dir)
      File.ln_s!(secret, Path.join(dir, "AGENTS.md"))

      assert {:import_paperclip, code, out} = ImportPaperclip.run([src, "--as", "victim"])

      # Either no agents were found (run may report 0) — the secret must
      # never reach the imported AGENT.md.
      agent_md = Path.join([home, "companies", "victim", "agents", "evil", "AGENT.md"])
      refute File.exists?(agent_md)
      assert code in [0, 1]
      refute out =~ "SSH PRIVATE KEY"
    end

    # A symlinked agent directory is refused by the real_dir? lstat
    # guard (it reports :symlink, not :directory).
    test "does not follow a symlinked agent directory", %{src: src, home: home} do
      # Real foreign agent tree elsewhere.
      foreign = Path.join(home, "foreign-agent")
      File.mkdir_p!(foreign)
      File.write!(Path.join(foreign, "AGENTS.md"), "FOREIGN SECRET BODY\n")

      File.ln_s!(foreign, Path.join(src, "linked"))

      assert {:import_paperclip, _code, _out} = ImportPaperclip.run([src, "--as", "victim2"])

      refute File.exists?(
               Path.join([home, "companies", "victim2", "agents", "linked", "AGENT.md"])
             )
    end

    # On --force re-import, a pre-planted symlink at the destination
    # AGENT.md must NOT be followed (it would redirect the write outside
    # the company tree). safe_write! refuses; the symlink target is
    # untouched.
    test "refuses to write through a symlinked destination AGENT.md on --force", %{
      src: src,
      home: home
    } do
      seed_paperclip_agent(src, "ceo", %{"AGENTS.md" => "first body\n"})
      assert {:import_paperclip, 0, _} = ImportPaperclip.run([src, "--as", "victim4"])

      outside = Path.join(home, "outside-secret.txt")
      File.write!(outside, "DO NOT OVERWRITE\n")

      dest_agent_md = Path.join([home, "companies", "victim4", "agents", "ceo", "AGENT.md"])
      File.rm!(dest_agent_md)
      File.ln_s!(outside, dest_agent_md)

      File.write!(Path.join([src, "ceo", "AGENTS.md"]), "second body\n")

      assert_raise File.Error, fn ->
        ImportPaperclip.run([src, "--as", "victim4", "--force"])
      end

      # The symlink target outside the company tree is untouched.
      assert File.read!(outside) == "DO NOT OVERWRITE\n"
    end

    # A real AGENTS.md imports fine, but a symlinked companion
    # (SOUL.md -> secret) is skipped, not copied.
    test "skips a symlinked companion file", %{src: src, home: home} do
      secret = Path.join(home, "companion-secret.txt")
      File.write!(secret, "COMPANION SECRET\n")

      dir = Path.join(src, "ceo")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "AGENTS.md"), "legit body\n")
      File.ln_s!(secret, Path.join(dir, "SOUL.md"))

      assert {:import_paperclip, 0, _out} = ImportPaperclip.run([src, "--as", "acme5"])

      agent_dir = Path.join([home, "companies", "acme5", "agents", "ceo"])
      assert File.exists?(Path.join(agent_dir, "AGENT.md"))
      # The symlinked SOUL.md was NOT copied.
      refute File.exists?(Path.join(agent_dir, "SOUL.md"))
    end
  end
end
