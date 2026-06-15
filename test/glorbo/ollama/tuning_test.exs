defmodule Glorbo.Ollama.TuningTest do
  use ExUnit.Case, async: true

  alias Glorbo.Ollama.Tuning

  test "tuned_name appends -glorbo to the tag, or :glorbo when untagged" do
    assert Tuning.tuned_name("llama3.1:8b") == "llama3.1:8b-glorbo"

    assert Tuning.tuned_name("registry/library/llama3:latest") ==
             "registry/library/llama3:latest-glorbo"

    assert Tuning.tuned_name("mistral") == "mistral:glorbo"
  end

  test "modelfile bakes FROM + the configured PARAMETERs in a stable order" do
    mf = Tuning.modelfile("llama3.1:8b", %{num_ctx: 32_768, temperature: 0.7, top_p: 0.9})

    assert mf ==
             "FROM llama3.1:8b\nPARAMETER num_ctx 32768\nPARAMETER temperature 0.7\nPARAMETER top_p 0.9\n"
  end

  test "ensure_tuned returns the base unchanged when no knobs are configured" do
    config = %{daemon: %{}, models: %{}}
    assert {:ok, "mistral"} = Tuning.ensure_tuned("mistral", config: config)
  end

  test "ensure_tuned creates the derived model + returns its name" do
    parent = self()
    config = %{daemon: %{}, models: %{"llama3.1:8b" => %{num_ctx: 32_768}}}

    create_fun = fn name, mf ->
      send(parent, {:create, name, mf})
      :ok
    end

    assert {:ok, "llama3.1:8b-glorbo"} =
             Tuning.ensure_tuned("llama3.1:8b", config: config, create_fun: create_fun)

    assert_received {:create, "llama3.1:8b-glorbo", "FROM llama3.1:8b\nPARAMETER num_ctx 32768\n"}
  end

  test "ensure_tuned surfaces a create failure" do
    config = %{daemon: %{}, models: %{"m" => %{num_ctx: 4096}}}

    assert {:error, :boom} =
             Tuning.ensure_tuned("m",
               config: config,
               create_fun: fn _n, _m -> {:error, :boom} end
             )
  end

  test "ensure_tuned re-validates the base model name even if config carried a bad one" do
    config = %{daemon: %{}, models: %{"evil; x" => %{num_ctx: 4096}}}

    assert {:error, :invalid_model} =
             Tuning.ensure_tuned("evil; x", config: config, create_fun: fn _n, _m -> :ok end)
  end
end
