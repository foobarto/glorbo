defmodule Glorbo.Company.RouterMemoryScalarTest do
  @moduledoc """
  Codex L94 — memory frontmatter scalar guard on the router write path.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Company.Router
  alias Glorbo.Test.TmpGlorboHome

  @company "acme"

  defp capturing_audit_fun(pid) do
    fn _server, entry -> send(pid, {:audit, entry}) end
  end

  defp scaffold_company(base, agents) do
    co_dir = Path.join([base, "companies", @company])
    File.mkdir_p!(Path.join(co_dir, "channels"))
    File.mkdir_p!(Path.join(co_dir, "history"))
    File.mkdir_p!(Path.join(co_dir, "audit"))

    Enum.each(agents, fn slug ->
      agent_dir = Path.join([co_dir, "agents", slug])
      File.mkdir_p!(Path.join(agent_dir, "inbox"))
      File.mkdir_p!(Path.join([agent_dir, "inbox", "mentions"]))
      File.mkdir_p!(Path.join([agent_dir, "inbox", "rejections"]))
      File.mkdir_p!(Path.join(agent_dir, "outbox"))
    end)

    co_dir
  end

  defp start_router!(base) do
    name = Glorbo.Test.UniqueName.gen("router")

    pid =
      start_supervised!(
        {Router,
         [
           name: name,
           company: @company,
           base: base,
           audit_fun: capturing_audit_fun(self())
         ]}
      )

    {name, pid}
  end

  setup do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    {name, _pid} = start_router!(base)
    memory_outbox = Path.join([base, "companies", @company, "agents/ceo/outbox/memory"])
    File.mkdir_p!(memory_outbox)
    {:ok, base: base, router: name, outbox: memory_outbox}
  end

  describe "memory write routing — scalar frontmatter (codex L94)" do
    test "non-scalar name/description frontmatter is rejected before write",
         %{base: base, router: router, outbox: outbox} do
      cases = [
        {"feedback_map_name.md",
         """
         ---
         kind: agent-memory/v1
         name:
           key: value
         type: feedback
         ---

         body
         """},
        {"feedback_list_desc.md",
         """
         ---
         kind: agent-memory/v1
         name: OK
         description:
           - item
         type: feedback
         ---

         body
         """}
      ]

      for {filename, content} <- cases do
        File.write!(Path.join(outbox, filename), content)

        send(router, {:file_event, "agents/ceo/outbox/memory/#{filename}", [:created]})
        _ = :sys.get_state(router)

        refute File.exists?(Path.join([base, "companies/acme/agents/ceo/memory", filename]))
        refute File.exists?(Path.join(outbox, filename))
        assert_receive {:audit, %{action: "memory.rejected"}}
      end
    end
  end
end
