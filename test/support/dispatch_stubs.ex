defmodule Glorbo.Agent.DispatchTest.StubAdapter do
  @moduledoc false
  @behaviour Glorbo.CLI.Adapter

  @impl true
  def binary, do: "/fake/claude"

  @impl true
  def args(_spec, _prompt_path, _opts), do: ["--print"]

  @impl true
  def env(_spec, workspace),
    do: %{"CLAUDE_CONFIG_DIR" => Path.join(workspace, ".glorbo-claude")}

  @impl true
  def usage_path(_spec, _workspace), do: :stdout

  @impl true
  def parse_usage({:stdout, _blob}),
    do: {:ok, %{prompt_tokens: 42, completion_tokens: 7, model: "claude-opus-4-6"}}

  def parse_usage({:jsonl_file, _}), do: {:error, :unsupported}
end

defmodule Glorbo.Agent.DispatchTest.NilModelAdapter do
  @moduledoc false
  @behaviour Glorbo.CLI.Adapter

  @impl true
  def binary, do: "/fake/codex"

  @impl true
  def args(_spec, _prompt_path, _opts), do: []

  @impl true
  def env(_spec, _workspace), do: %{}

  @impl true
  def usage_path(_spec, _workspace), do: :stdout

  @impl true
  def parse_usage({:stdout, _blob}),
    do: {:ok, %{prompt_tokens: 100, completion_tokens: 50, model: nil}}

  def parse_usage(_), do: {:error, :unsupported}
end
