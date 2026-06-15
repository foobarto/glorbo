defmodule Glorbo.Ollama.ConfigTest do
  use ExUnit.Case, async: true

  alias Glorbo.Ollama.Config

  defp write_config(content) do
    path = Path.join(System.tmp_dir!(), "ollama-#{System.unique_integer([:positive])}.toml")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "loads daemon + per-model knobs" do
    path =
      write_config("""
      [daemon]
      num_parallel = 4
      max_loaded_models = 2
      keep_alive = "10m"

      [models."llama3.1:8b"]
      num_ctx = 32_768
      temperature = 0.7
      num_predict = 4096
      top_p = 0.9
      """)

    c = Config.load(path: path)
    assert c.daemon == %{num_parallel: 4, max_loaded_models: 2, keep_alive: "10m"}

    assert Config.model_params(c, "llama3.1:8b") == %{
             num_ctx: 32_768,
             temperature: 0.7,
             num_predict: 4096,
             top_p: 0.9
           }

    assert Config.tuned?(c, "llama3.1:8b")
    refute Config.tuned?(c, "mistral")
  end

  test "daemon_env builds the OLLAMA_* env list, omitting unset knobs" do
    path = write_config("[daemon]\nnum_parallel = 3\n")
    assert Config.daemon_env(Config.load(path: path)) == [{"OLLAMA_NUM_PARALLEL", "3"}]
  end

  test "drops out-of-range / wrong-type values, keeps the valid ones" do
    path =
      write_config("""
      [daemon]
      num_parallel = 9999
      max_loaded_models = 2

      [models."m"]
      num_ctx = -5
      temperature = 5.0
      top_p = 0.5
      """)

    c = Config.load(path: path)
    # num_parallel out of range → dropped; max_loaded_models kept.
    assert c.daemon == %{max_loaded_models: 2}
    # negative num_ctx + temperature>2 → dropped; top_p kept.
    assert Config.model_params(c, "m") == %{top_p: 0.5}
  end

  test "rejects an invalid model-name key (it flows into /api/create)" do
    path = write_config("[models.\"evil; rm -rf\"]\nnum_ctx = 4096\n")
    assert Config.load(path: path).models == %{}
  end

  test "missing or empty file → empty config" do
    assert Config.load(path: "/nonexistent/ollama.toml") == %{daemon: %{}, models: %{}}
  end
end
