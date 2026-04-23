defmodule Glorbo.Network.ProxyTokensTest do
  use ExUnit.Case, async: false

  alias Glorbo.Network.ProxyTokens

  setup do
    ProxyTokens.ensure_started()
    # Table is global + named; don't fight test ordering — just
    # count size before so we can cleanup after.
    :ets.delete_all_objects(:glorbo_proxy_tokens)
    :ok
  end

  describe "register/1" do
    test "returns a url-safe 32-byte encoded token" do
      {:ok, token} =
        ProxyTokens.register(%{
          company: "acme",
          agent: "ceo",
          dispatch_id: "d-1",
          expires_in_ms: 60_000
        })

      assert is_binary(token)
      # 32 bytes, url-safe base64, no padding → 43 chars.
      assert byte_size(token) == 43
      assert Regex.match?(~r/\A[A-Za-z0-9_\-]+\z/, token)
    end

    test "two registrations return distinct tokens" do
      {:ok, a} =
        ProxyTokens.register(%{
          company: "acme",
          agent: "ceo",
          dispatch_id: "d-1",
          expires_in_ms: 60_000
        })

      {:ok, b} =
        ProxyTokens.register(%{
          company: "acme",
          agent: "ceo",
          dispatch_id: "d-2",
          expires_in_ms: 60_000
        })

      assert a != b
    end
  end

  describe "resolve/1" do
    test "returns the registered entry" do
      {:ok, token} =
        ProxyTokens.register(%{
          company: "acme",
          agent: "ceo",
          dispatch_id: "d-abc",
          expires_in_ms: 60_000
        })

      assert {:ok, %{company: "acme", agent: "ceo", dispatch_id: "d-abc"}} =
               ProxyTokens.resolve(token)
    end

    test ":error for an unknown token" do
      assert :error = ProxyTokens.resolve("nope-not-a-real-token")
    end

    test ":error and lazy-delete for expired tokens" do
      {:ok, token} =
        ProxyTokens.register(%{
          company: "acme",
          agent: "ceo",
          dispatch_id: "d-1",
          expires_in_ms: 1
        })

      # Let the monotonic clock tick past 1ms.
      Process.sleep(5)

      assert :error = ProxyTokens.resolve(token)
      # Expired entry was lazy-deleted.
      assert ProxyTokens.size() == 0
    end

    test ":error for non-string inputs" do
      assert :error = ProxyTokens.resolve(nil)
      assert :error = ProxyTokens.resolve(12_345)
    end
  end

  describe "revoke/1" do
    test "drops the entry" do
      {:ok, token} =
        ProxyTokens.register(%{
          company: "acme",
          agent: "ceo",
          dispatch_id: "d-1",
          expires_in_ms: 60_000
        })

      assert {:ok, _} = ProxyTokens.resolve(token)
      :ok = ProxyTokens.revoke(token)
      assert :error = ProxyTokens.resolve(token)
    end

    test "is idempotent — revoking a missing token is :ok" do
      assert :ok = ProxyTokens.revoke("definitely-not-a-token")
      assert :ok = ProxyTokens.revoke("")
      assert :ok = ProxyTokens.revoke(nil)
    end
  end
end
