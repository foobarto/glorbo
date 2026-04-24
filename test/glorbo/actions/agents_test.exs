defmodule Glorbo.Actions.AgentsTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Agents` (GEP-36 Round M-6).
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Agents
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
    ag_dir = Path.join([base, "companies", "acme", "agents", "ceo"])
    File.mkdir_p!(Path.join(ag_dir, "workspace"))
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, ag_dir: ag_dir}
  end

  describe "create_workspace_file/4" do
    test "writes empty file + emits agent.file_create audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, %{abs_path: abs}} =
               Agents.create_workspace_file("acme", "ceo", "workspace/notes.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert abs == Path.join(ag_dir, "workspace/notes.md")
      assert File.read!(abs) == ""

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.file_create"
      assert event[:target] == "agents/ceo/workspace/notes.md"
      assert event[:company] == "acme"
      assert event[:agent] == "ceo"
    end

    test "refuses to overwrite existing file",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      path = Path.join(ag_dir, "workspace/existing.md")
      File.write!(path, "content")

      assert {:error, :already_exists} =
               Agents.create_workspace_file("acme", "ceo", "workspace/existing.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(path) == "content"
      assert FakeAudit.calls(audit) == []
    end

    test "refuses contract files (threatmodel H9)",
         %{base: base, audit: audit} do
      assert {:error, :contract_file} =
               Agents.create_workspace_file("acme", "ceo", "AGENT.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:error, :contract_file} =
               Agents.create_workspace_file("acme", "ceo", "stdout.log",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "refuses path traversal",
         %{base: base, audit: audit} do
      assert {:error, :invalid_path} =
               Agents.create_workspace_file("acme", "ceo", "../../etc/passwd",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "refuses symlink on path (threatmodel H10)",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      decoy = Path.join(ag_dir, "decoy-dir")
      File.mkdir_p!(decoy)
      swapped = Path.join(ag_dir, "workspace_symlink")
      File.ln_s!(decoy, swapped)

      assert {:error, :symlink_in_path} =
               Agents.create_workspace_file(
                 "acme",
                 "ceo",
                 "workspace_symlink/under-symlink.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "write_workspace_file/5" do
    setup %{ag_dir: ag_dir} do
      File.write!(Path.join(ag_dir, "workspace/doc.md"), "old body\n")
      :ok
    end

    test "overwrites file + emits agent.file_write audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, _} =
               Agents.write_workspace_file(
                 "acme",
                 "ceo",
                 "workspace/doc.md",
                 "new body\n",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(Path.join(ag_dir, "workspace/doc.md")) == "new body\n"

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.file_write"
      assert event[:target] == "agents/ceo/workspace/doc.md"
    end

    test "refuses contract-file overwrite (H9)",
         %{base: base, audit: audit} do
      assert {:error, :contract_file} =
               Agents.write_workspace_file(
                 "acme",
                 "ceo",
                 "AGENT.md",
                 "pwned",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "trash_workspace_file/4" do
    setup %{ag_dir: ag_dir} do
      File.write!(Path.join(ag_dir, "workspace/doomed.md"), "goodbye\n")
      :ok
    end

    test "moves file into history/deleted/<ts>-<basename> + emits audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, %{dest_rel_path: dest_rel}} =
               Agents.trash_workspace_file("acme", "ceo", "workspace/doomed.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert dest_rel =~ ~r|\Ahistory/deleted/\d+-doomed\.md\z|
      refute File.exists?(Path.join(ag_dir, "workspace/doomed.md"))
      assert File.exists?(Path.join(ag_dir, dest_rel))

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.file_trash"
      assert event[:target] == "agents/ceo/workspace/doomed.md"
      assert event[:dest] == Path.join(["agents", "ceo", dest_rel])
    end

    test "returns :not_found on missing file",
         %{base: base, audit: audit} do
      assert {:error, :not_found} =
               Agents.trash_workspace_file("acme", "ceo", "workspace/ghost.md",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "retire/3" do
    test "moves agent dir to .archive/<slug>-<ts>/ + emits agent.retire audit",
         %{base: base, audit: audit, ag_dir: ag_dir} do
      assert {:ok, %{archive_rel_path: archive_rel}} =
               Agents.retire("acme", "ceo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert archive_rel =~ ~r|\Aagents/\.archive/ceo-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}|
      refute File.dir?(ag_dir)
      assert File.dir?(Path.join([base, "companies", "acme", archive_rel]))

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.retire"
      assert event[:target] == "agents/ceo"
      assert event[:dest] == archive_rel
    end

    test "returns :not_found on missing agent dir",
         %{base: base, audit: audit} do
      assert {:error, :not_found} =
               Agents.retire("acme", "ghost",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid slug",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :agent, "../evil"}} =
               Agents.retire("acme", "../evil",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end
end
