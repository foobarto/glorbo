defmodule Glorbo.Actions.ProjectsTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Projects` (GEP-36 Round M-2).
  Mirrors the shape of `Glorbo.Actions.CompaniesTest`.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Projects
  alias Glorbo.Test.TmpGlorboHome

  defmodule FakeAudit do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, []}

    @impl true
    def handle_call({:append, entry}, _from, state),
      do: {:reply, :ok, [entry | state]}

    def handle_call(:calls, _from, state),
      do: {:reply, Enum.reverse(state), state}
  end

  setup do
    base = TmpGlorboHome.setup()
    proj_dir = Path.join([base, "companies", "acme", "projects", "demo"])
    File.mkdir_p!(proj_dir)
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, proj_dir: proj_dir}
  end

  describe "ensure_stub/3" do
    test "creates skeleton project.md on first call and emits project.create",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      refute File.exists?(Path.join(proj_dir, "project.md"))

      assert {:ok, :created} =
               Projects.ensure_stub("acme", "demo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      content = File.read!(Path.join(proj_dir, "project.md"))
      assert content =~ "kind: project/v1"
      assert content =~ "slug: demo"

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "project.create"
      assert event[:actor] == "director"
      assert event[:target] == "projects/demo/project.md"
      assert event[:company] == "acme"
      assert event[:project] == "demo"
    end

    test "is idempotent when file exists — no write, no audit",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      path = Path.join(proj_dir, "project.md")
      File.write!(path, "---\nkind: project/v1\nslug: demo\nname: Demo\n---\n")
      mtime_before = File.stat!(path, time: :posix).mtime

      assert {:ok, :exists} =
               Projects.ensure_stub("acme", "demo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.stat!(path, time: :posix).mtime == mtime_before
      assert FakeAudit.calls(audit) == []
    end

    test "refuses symlinks (threatmodel M19)",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      path = Path.join(proj_dir, "project.md")
      target = Path.join(proj_dir, "some-other-file")
      File.write!(target, "x")
      File.ln_s!(target, path)

      assert {:error, :not_a_regular_file} =
               Projects.ensure_stub("acme", "demo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid company or project slugs",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Projects.ensure_stub("../etc", "demo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:error, {:invalid_slug, :project, "../etc"}} =
               Projects.ensure_stub("acme", "../etc",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "update/4" do
    setup %{proj_dir: proj_dir} do
      File.write!(
        Path.join(proj_dir, "project.md"),
        "---\nkind: project/v1\nslug: demo\n---\nBody paragraph.\n"
      )

      :ok
    end

    test "writes frontmatter fields + preserves body + emits project.update",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      meta = %{name: "Demo Corp", icon: "📦", description: "widgets"}

      assert {:ok, %{abs_path: abs}} =
               Projects.update("acme", "demo", meta,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert abs == Path.join(proj_dir, "project.md")
      content = File.read!(abs)
      assert content =~ ~s(name: "Demo Corp")
      assert content =~ ~s(icon: "📦")
      assert content =~ ~s(description: "widgets")
      assert content =~ "Body paragraph."

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "project.update"
      assert event[:target] == "projects/demo/project.md"
      assert event[:company] == "acme"
      assert event[:project] == "demo"
      assert event["name"] == "Demo Corp"
    end

    test "escapes embedded quotes and newlines in field values",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      meta = %{name: ~s(a "quoted" name), icon: nil, description: "line1\nline2"}

      assert {:ok, _} =
               Projects.update("acme", "demo", meta,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      content = File.read!(Path.join(proj_dir, "project.md"))
      assert content =~ ~s(name: "a \\"quoted\\" name")
      assert content =~ ~s(description: "line1 line2")
    end

    test "drops nil and empty values from frontmatter",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      meta = %{name: "Demo", icon: "", description: nil}

      assert {:ok, _} =
               Projects.update("acme", "demo", meta,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      content = File.read!(Path.join(proj_dir, "project.md"))
      assert content =~ ~s(name: "Demo")
      refute content =~ "icon:"
      refute content =~ "description:"
    end

    test "refuses symlinks at the target (threatmodel M19)",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      path = Path.join(proj_dir, "project.md")
      File.rm!(path)
      target = Path.join(proj_dir, "decoy")
      File.write!(target, "x")
      File.ln_s!(target, path)

      assert {:error, :not_a_regular_file} =
               Projects.update("acme", "demo", %{name: "x"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "cleans up .tmp on rename failure",
         %{base: base, audit: audit, proj_dir: proj_dir} do
      # Make the target a directory so rename fails predictably.
      target = Path.join(proj_dir, "project.md")
      File.rm!(target)
      File.mkdir_p!(target)

      assert {:error, _} =
               Projects.update("acme", "demo", %{name: "x"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      refute File.exists?(Path.join(proj_dir, "project.md.tmp"))
    end

    test "rejects invalid slugs",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Projects.update("../etc", "demo", %{name: "x"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end
end
