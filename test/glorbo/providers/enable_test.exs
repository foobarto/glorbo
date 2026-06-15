defmodule Glorbo.Providers.EnableTest do
  use ExUnit.Case, async: true

  alias Glorbo.Providers.Enable

  defp tmp_toml(ctx) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glorbo-enable-#{ctx.test |> inspect() |> String.replace(~r/\W/, "")}-#{System.unique_integer([:positive])}"
      )

    path = Path.join(dir, "providers.toml")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end

  defp ready(alias_name, endpoint \\ "http://127.0.0.1:11434") do
    %{alias: alias_name, endpoint: endpoint, status: :ready, detail: nil}
  end

  test "writes a [[providers]] block with kind=native + auth=none", ctx do
    path = tmp_toml(ctx)

    assert :ok = Enable.enable("ollama", path: path, detection: ready("ollama"))

    body = File.read!(path)
    assert body =~ ~s{[[providers]]}
    assert body =~ ~s{name         = "ollama"}
    assert body =~ ~s{kind         = "native"}
    assert body =~ ~s{endpoint     = "http://127.0.0.1:11434"}
    assert body =~ ~s{auth         = "none"}
    assert body =~ ~s{usage_parser = "native-v1"}
    # Ollama uses its native /api/tags model-list path.
    assert body =~ ~s(path = "/api/tags", shape = "ollama")
  end

  test "openai-shape aliases get /v1/models + openai shape", ctx do
    path = tmp_toml(ctx)

    assert :ok =
             Enable.enable("llamacpp",
               path: path,
               detection: ready("llamacpp", "http://127.0.0.1:8080")
             )

    body = File.read!(path)
    assert body =~ ~s(path = "/v1/models", shape = "openai")
  end

  test "preserves existing file contents", ctx do
    path = tmp_toml(ctx)

    File.write!(path, """
    # user-maintained providers
    [[providers]]
    name = "custom-local"
    kind = "native"
    endpoint = "http://127.0.0.1:9999"
    """)

    assert :ok =
             Enable.enable("vllm", path: path, detection: ready("vllm", "http://127.0.0.1:8000"))

    body = File.read!(path)
    # Original entry still present.
    assert body =~ ~s(name = "custom-local")
    # New entry appended.
    assert body =~ ~s{name         = "vllm"}
  end

  test "is idempotent — second enable returns :already_enabled", ctx do
    path = tmp_toml(ctx)

    assert :ok = Enable.enable("lm-studio", path: path, detection: ready("lm-studio"))

    assert {:error, :already_enabled} =
             Enable.enable("lm-studio", path: path, detection: ready("lm-studio"))
  end

  test "refuses to enable a provider that isn't :ready" do
    assert {:error, :not_reachable} =
             Enable.enable("ollama",
               detection: %{
                 alias: "ollama",
                 endpoint: "",
                 status: :unreachable,
                 detail: :econnrefused
               }
             )
  end

  test "default_path/0 is ~/.glorbo/providers.toml" do
    assert Enable.default_path() |> String.ends_with?("providers.toml")
  end

  test "creates config dir and providers.toml with restrictive permissions", ctx do
    path = tmp_toml(ctx)

    assert :ok = Enable.enable("ollama", path: path, detection: ready("ollama"))

    assert {:ok, %File.Stat{mode: file_mode}} = File.stat(path)
    assert Bitwise.band(file_mode, 0o777) == 0o600

    dir = Path.dirname(path)
    assert {:ok, %File.Stat{mode: dir_mode}} = File.stat(dir)
    assert Bitwise.band(dir_mode, 0o777) == 0o700
  end
end
