defmodule Glorbo.Actions.ChannelsTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Channels` (GEP-36 Round M-4).
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Channels
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
    co_dir = Path.join([base, "companies", "acme"])
    File.mkdir_p!(co_dir)
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, co_dir: co_dir}
  end

  describe "create/3" do
    test "materializes channel file with canonical header + emits channel.create",
         %{base: base, audit: audit, co_dir: co_dir} do
      assert {:ok, %{rel_path: rel, abs_path: abs}} =
               Channels.create("acme", "eng",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert rel == "channels/eng.md"
      assert abs == Path.join([co_dir, "channels", "eng.md"])
      content = File.read!(abs)
      assert content =~ "kind: channel-log/v1"
      assert content =~ "channel: eng"
      assert content =~ "# #eng"

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "channel.create"
      assert event[:actor] == "director"
      assert event[:target] == "channels/eng.md"
      assert event[:company] == "acme"
      assert event[:channel] == "eng"
    end

    test "returns :already_exists without rewriting or emitting",
         %{base: base, audit: audit, co_dir: co_dir} do
      File.mkdir_p!(Path.join(co_dir, "channels"))
      existing = Path.join([co_dir, "channels", "eng.md"])
      File.write!(existing, "pre-existing")

      assert {:error, :already_exists} =
               Channels.create("acme", "eng",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(existing) == "pre-existing"
      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid channel slug",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :channel, "foo bar"}} =
               Channels.create("acme", "foo bar",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid company slug",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Channels.create("../etc", "eng",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  describe "archive/3" do
    setup %{co_dir: co_dir} do
      channels = Path.join(co_dir, "channels")
      File.mkdir_p!(channels)
      File.write!(Path.join(channels, "eng.md"), "log")
      :ok
    end

    test "moves channel into .archive/ and emits channel.archive",
         %{base: base, audit: audit, co_dir: co_dir} do
      assert {:ok, %{dest_rel_path: dest_rel}} =
               Channels.archive("acme", "eng",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert dest_rel == "channels/.archive/eng.md"
      refute File.exists?(Path.join([co_dir, "channels", "eng.md"]))
      assert File.exists?(Path.join([co_dir, "channels", ".archive", "eng.md"]))

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "channel.archive"
      assert event[:target] == "channels/eng.md"
      assert event[:dest] == "channels/.archive/eng.md"
      assert event[:channel] == "eng"
    end

    test "refuses to archive general",
         %{base: base, audit: audit, co_dir: co_dir} do
      File.write!(Path.join([co_dir, "channels", "general.md"]), "canon")

      assert {:error, :not_archivable} =
               Channels.archive("acme", "general",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "refuses to archive director DMs",
         %{base: base, audit: audit, co_dir: co_dir} do
      File.write!(Path.join([co_dir, "channels", "dm-director--ceo.md"]), "dm")

      assert {:error, :not_archivable} =
               Channels.archive("acme", "dm-director--ceo",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "returns :not_found when source channel is missing",
         %{base: base, audit: audit} do
      assert {:error, :not_found} =
               Channels.archive("acme", "ghost",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end
end
