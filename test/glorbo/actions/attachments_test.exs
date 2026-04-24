defmodule Glorbo.Actions.AttachmentsTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Attachments` (GEP-36 Round M-5c).
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Attachments
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
    tmp_dir = Path.join(base, "uploads-tmp")
    File.mkdir_p!(tmp_dir)
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, tmp_dir: tmp_dir}
  end

  describe "ingest/6" do
    test "copies uploaded file + emits attachment.upload audit",
         %{base: base, audit: audit, tmp_dir: tmp_dir} do
      tmp = Path.join(tmp_dir, "upload-abc.tmp")
      File.write!(tmp, "binary-payload")

      assert {:ok, rel} =
               Attachments.ingest(
                 "acme",
                 "demo",
                 "demo-01",
                 tmp,
                 "my-notes.pdf",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert rel == "attachments/demo-01/my-notes.pdf"

      abs_dest =
        Path.join([
          base,
          "companies",
          "acme",
          "projects",
          "demo",
          "attachments",
          "demo-01",
          "my-notes.pdf"
        ])

      assert File.read!(abs_dest) == "binary-payload"
      # tmp is intentionally left alone — LiveView's upload machinery
      # is what cleans it.
      assert File.exists?(tmp)

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "attachment.upload"
      assert event[:actor] == "director"
      assert event[:target] == "projects/demo/attachments/demo-01/my-notes.pdf"
      assert event[:company] == "acme"
      assert event[:project] == "demo"
      assert event[:task_id] == "demo-01"
      assert event[:filename] == "my-notes.pdf"
      assert event["client_name"] == "my-notes.pdf"
    end

    test "sanitizes unsafe client names",
         %{base: base, audit: audit, tmp_dir: tmp_dir} do
      tmp = Path.join(tmp_dir, "upload-xyz.tmp")
      File.write!(tmp, "x")

      # Sanitizer keeps dots + dashes + word chars; `..` survives as
      # a literal middle-of-filename substring (safe — it's not a
      # path separator component, just text inside a single filename).
      assert {:ok, "attachments/demo-01/spooky_file___..__evil.sh"} =
               Attachments.ingest(
                 "acme",
                 "demo",
                 "demo-01",
                 tmp,
                 "spooky file / ../ evil.sh",
                 actor: "director",
                 base: base,
                 audit: audit
               )
    end

    test "creates the destination directory idempotently",
         %{base: base, audit: audit, tmp_dir: tmp_dir} do
      tmp = Path.join(tmp_dir, "u1.tmp")
      File.write!(tmp, "a")
      tmp2 = Path.join(tmp_dir, "u2.tmp")
      File.write!(tmp2, "b")

      assert {:ok, _} =
               Attachments.ingest("acme", "demo", "demo-01", tmp, "one.txt",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:ok, _} =
               Attachments.ingest("acme", "demo", "demo-01", tmp2, "two.txt",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.ls!(
               Path.join([
                 base,
                 "companies",
                 "acme",
                 "projects",
                 "demo",
                 "attachments",
                 "demo-01"
               ])
             )
             |> Enum.sort() == ["one.txt", "two.txt"]
    end

    test "rejects invalid slugs / task_id",
         %{base: base, audit: audit, tmp_dir: tmp_dir} do
      tmp = Path.join(tmp_dir, "u.tmp")
      File.write!(tmp, "x")

      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Attachments.ingest("../etc", "demo", "demo-01", tmp, "f.txt",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:error, {:invalid_slug, :project, "../etc"}} =
               Attachments.ingest("acme", "../etc", "demo-01", tmp, "f.txt",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:error, {:invalid_task_id, "../evil"}} =
               Attachments.ingest("acme", "demo", "../evil", tmp, "f.txt",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "returns :enoent from File.cp/2 when tmp_path is missing",
         %{base: base, audit: audit} do
      assert {:error, :enoent} =
               Attachments.ingest(
                 "acme",
                 "demo",
                 "demo-01",
                 "/tmp/nonexistent-file-for-test-#{System.unique_integer([:positive])}",
                 "anything.bin",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "sanitize_filename/1" do
    test "maps non-filename chars to _ and strips leading dots" do
      assert Attachments.sanitize_filename("normal.txt") == "normal.txt"
      assert Attachments.sanitize_filename("..hidden") == "hidden"
      assert Attachments.sanitize_filename(".") == "file"
      assert Attachments.sanitize_filename("") == "file"
      assert Attachments.sanitize_filename("with spaces.txt") == "with_spaces.txt"
      assert Attachments.sanitize_filename("a/b/c.bin") == "a_b_c.bin"
    end
  end
end
