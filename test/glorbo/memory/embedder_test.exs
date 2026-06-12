defmodule Glorbo.Memory.EmbedderTest do
  use ExUnit.Case, async: true

  alias Glorbo.Memory.Embedder

  describe "embed/3 with an injected embed_fun (no real server)" do
    test "passes model + texts through to the stub" do
      fun = fn model, texts ->
        send(self(), {:called, model, texts})
        {:ok, Enum.map(texts, fn _ -> [1.0, 2.0] end)}
      end

      assert {:ok, [[1.0, 2.0], [1.0, 2.0]]} =
               Embedder.embed("my-model", ["a", "b"], embed_fun: fun)

      assert_received {:called, "my-model", ["a", "b"]}
    end

    test "empty input short-circuits to {:ok, []} without calling the fun" do
      fun = fn _m, _t -> flunk("embed_fun must not be called for empty input") end
      assert {:ok, []} = Embedder.embed("m", [], embed_fun: fun)
    end

    test "propagates a stub error" do
      fun = fn _m, _t -> {:error, :stub_down} end
      assert {:error, :stub_down} = Embedder.embed("m", ["x"], embed_fun: fun)
    end
  end

  describe "default embed_fun (no endpoint)" do
    test "returns :endpoint_missing when no endpoint is configured" do
      assert {:error, :endpoint_missing} = Embedder.embed("m", ["x"], [])
    end
  end
end
