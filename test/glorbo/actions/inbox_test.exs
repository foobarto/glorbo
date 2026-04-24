defmodule Glorbo.Actions.InboxTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Inbox.deliver_task_assignment/6`
  (GEP-36 Round M-5a).
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Inbox
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
    agents_dir = Path.join([base, "companies", "acme", "agents"])
    File.mkdir_p!(Path.join(agents_dir, "ceo"))
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, agents_dir: agents_dir}
  end

  describe "deliver_task_assignment/6" do
    test "writes inbox-message file + emits inbox.deliver audit",
         %{base: base, audit: audit, agents_dir: agents_dir} do
      assert {:ok, %{rel_path: rel, abs_path: abs, agent: "ceo"}} =
               Inbox.deliver_task_assignment(
                 "acme",
                 "ceo",
                 "demo-01",
                 "Draft Q2 plan",
                 "Please outline the Q2 priorities.",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert rel =~ ~r|\Aagents/ceo/inbox/\d+-task-demo-01\.md\z|
      content = File.read!(abs)
      assert content =~ "kind: inbox-message/v1"
      assert content =~ ~s(task_id: "demo-01")
      assert content =~ "subkind: task_assignment"
      assert content =~ "# New task assigned: Draft Q2 plan"
      assert content =~ "Please outline the Q2 priorities."

      assert File.exists?(Path.join([agents_dir, "ceo", "inbox"]))

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "inbox.deliver"
      assert event[:actor] == "director"
      assert event[:target] == rel
      assert event[:company] == "acme"
      assert event[:agent] == "ceo"
      assert event[:task_id] == "demo-01"
      assert event[:subkind] == "task_assignment"
    end

    test "returns :agent_not_found when the agent directory is missing",
         %{base: base, audit: audit} do
      assert {:error, :agent_not_found} =
               Inbox.deliver_task_assignment(
                 "acme",
                 "ghost",
                 "demo-01",
                 "title",
                 "body",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid company or agent slug",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Inbox.deliver_task_assignment(
                 "../etc",
                 "ceo",
                 "demo-01",
                 "t",
                 "b",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert {:error, {:invalid_slug, :agent, "../evil"}} =
               Inbox.deliver_task_assignment(
                 "acme",
                 "../evil",
                 "demo-01",
                 "t",
                 "b",
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end
end
