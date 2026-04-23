defmodule Glorbo.Network.HistoryTest do
  use ExUnit.Case, async: false

  alias Glorbo.Network.History

  defp start_history!(company \\ "acme") do
    # Use a pid instead of a runtime-created atom name (T-03-15). The
    # GenServer.name() typespec accepts pid; Registry/GenServer.call
    # treats the pid as a direct target.
    id = {History, System.unique_integer([:positive])}

    pid =
      start_supervised!(Supervisor.child_spec({History, [name: nil, company: company]}, id: id))

    {pid, pid}
  end

  describe "fetch/4 + put/6" do
    test "miss → put → hit" do
      {name, _pid} = start_history!()

      assert :miss = History.fetch(name, "api.anthropic.com", 443)

      :ok = History.put(name, "api.anthropic.com", 443, :allow, :known_llm_host)

      assert {:hit, :allow, :known_llm_host} =
               History.fetch(name, "api.anthropic.com", 443)
    end

    test "deny verdict round-trips the same way" do
      {name, _pid} = start_history!()
      :ok = History.put(name, "evil.example.com", 443, :deny, :ad_tld)

      assert {:hit, :deny, :ad_tld} = History.fetch(name, "evil.example.com", 443)
    end

    test "different {host, port} pairs are independent" do
      {name, _pid} = start_history!()
      :ok = History.put(name, "api.example.com", 443, :allow, :r1)
      :ok = History.put(name, "api.example.com", 80, :deny, :r2)

      assert {:hit, :allow, :r1} = History.fetch(name, "api.example.com", 443)
      assert {:hit, :deny, :r2} = History.fetch(name, "api.example.com", 80)
    end

    test "second put replaces the prior entry" do
      {name, _pid} = start_history!()
      :ok = History.put(name, "h.example.com", 443, :allow, :first)
      :ok = History.put(name, "h.example.com", 443, :deny, :second)

      assert {:hit, :deny, :second} = History.fetch(name, "h.example.com", 443)
    end
  end

  describe "TTL" do
    test "expired entries evict on fetch and return :miss" do
      {name, _pid} = start_history!()

      :ok = History.put(name, "h.example.com", 443, :allow, :r, ttl_ms: 1)
      # Sleep past the TTL.
      Process.sleep(5)

      assert :miss = History.fetch(name, "h.example.com", 443)
      assert 0 = History.size(name)
    end

    test "fresh entries stay within TTL" do
      {name, _pid} = start_history!()
      :ok = History.put(name, "h.example.com", 443, :allow, :r, ttl_ms: 60_000)

      assert {:hit, :allow, :r} = History.fetch(name, "h.example.com", 443)
    end
  end

  describe "flush/1 + size/1" do
    test "flush drops every entry" do
      {name, _pid} = start_history!()
      :ok = History.put(name, "a.example", 443, :allow, :r)
      :ok = History.put(name, "b.example", 443, :deny, :r)
      assert History.size(name) == 2

      :ok = History.flush(name)

      assert History.size(name) == 0
      assert :miss = History.fetch(name, "a.example", 443)
    end
  end
end
