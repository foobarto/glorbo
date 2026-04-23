defmodule Glorbo.Providers.NativeConfigTest do
  use ExUnit.Case, async: true

  alias Glorbo.Providers.NativeConfig

  describe "parse_auth/1" do
    test "accepts known auth modes as atoms and strings" do
      assert {:ok, nil} = NativeConfig.parse_auth(nil)
      assert {:ok, :none} = NativeConfig.parse_auth(:none)
      assert {:ok, :bearer} = NativeConfig.parse_auth("bearer")
      assert {:ok, :api_key} = NativeConfig.parse_auth("api_key")
      assert {:ok, :api_key} = NativeConfig.parse_auth("api-key")
    end

    test "rejects unknown auth modes" do
      assert {:error, {:invalid_auth, "funky"}} = NativeConfig.parse_auth("funky")
    end
  end

  describe "credentials_dir/1 + default_credentials_path/2" do
    test "honours GLORBO_CREDENTIALS_DIR before falling back to the default" do
      env = fn
        "GLORBO_CREDENTIALS_DIR" -> "/tmp/fake-creds"
        _ -> nil
      end

      assert NativeConfig.credentials_dir(env_fun: env) == "/tmp/fake-creds"

      assert NativeConfig.default_credentials_path("openai", env_fun: env) ==
               "/tmp/fake-creds/openai.toml"
    end

    test "falls back to Hierarchy.native_credentials_dir when env is unset" do
      env = fn _ -> nil end
      expected = Glorbo.Filesystem.Hierarchy.native_credentials_dir()
      assert NativeConfig.credentials_dir(env_fun: env) == expected
    end
  end

  describe "load_credentials_from_path/2" do
    test "returns empty map for missing files" do
      read = fn _ -> {:error, :enoent} end
      assert {:ok, %{}} = NativeConfig.load_credentials_from_path("/missing.toml", read_fun: read)
    end

    test "returns empty map for nil path" do
      assert {:ok, %{}} = NativeConfig.load_credentials_from_path(nil, [])
    end

    test "parses TOML" do
      read = fn _ -> {:ok, ~s(api_key = "sk-test")} end

      assert {:ok, %{"api_key" => "sk-test"}} =
               NativeConfig.load_credentials_from_path("/ok.toml", read_fun: read)
    end

    test "surfaces unreadable files as {:credentials_read_failed, reason}" do
      read = fn _ -> {:error, :eacces} end

      assert {:error, {:credentials_read_failed, :eacces}} =
               NativeConfig.load_credentials_from_path("/denied.toml", read_fun: read)
    end

    test "surfaces malformed TOML" do
      read = fn _ -> {:ok, "= = ="} end

      assert {:error, {:invalid_credentials_toml, _}} =
               NativeConfig.load_credentials_from_path("/bad.toml", read_fun: read)
    end
  end

  describe "resolve_endpoint/2" do
    test "prefers the credentials override over the provider default" do
      assert {:ok, "https://override"} =
               NativeConfig.resolve_endpoint("https://default", %{
                 "endpoint" => "https://override"
               })
    end

    test "falls back to the provider endpoint" do
      assert {:ok, "https://default"} = NativeConfig.resolve_endpoint("https://default", %{})
    end

    test "rejects empty or nil endpoints" do
      assert {:error, :missing_endpoint} = NativeConfig.resolve_endpoint(nil, %{})
      assert {:error, :missing_endpoint} = NativeConfig.resolve_endpoint("", %{})
    end
  end

  describe "validate_auth/3" do
    test "nil and :none auth do not require api_key" do
      assert :ok = NativeConfig.validate_auth(nil, "openai", %{})
      assert :ok = NativeConfig.validate_auth(:none, "openai", %{})
    end

    test "bearer and api_key require a non-empty api_key" do
      assert :ok = NativeConfig.validate_auth(:bearer, "openai", %{"api_key" => "sk"})

      assert {:error, {:missing_api_key, "openai"}} =
               NativeConfig.validate_auth(:bearer, "openai", %{})

      assert {:error, {:missing_api_key, "openai"}} =
               NativeConfig.validate_auth(:api_key, "openai", %{"api_key" => ""})
    end
  end

  describe "auth_headers/2" do
    test "none yields no auth headers" do
      assert [] = NativeConfig.auth_headers(:none, %{"api_key" => "sk"})
    end

    test "bearer emits Authorization + openai org/project extras when present" do
      credentials = %{
        "api_key" => "sk-test",
        "extras" => %{"organization" => "org_123", "project" => "proj_abc"}
      }

      headers = NativeConfig.auth_headers(:bearer, credentials)

      assert {"authorization", "Bearer sk-test"} in headers
      assert {"openai-organization", "org_123"} in headers
      assert {"openai-project", "proj_abc"} in headers
    end

    test "bearer omits extras when absent or blank" do
      assert [{"authorization", "Bearer sk"}] =
               NativeConfig.auth_headers(:bearer, %{"api_key" => "sk"})

      assert [{"authorization", "Bearer sk"}] =
               NativeConfig.auth_headers(:bearer, %{
                 "api_key" => "sk",
                 "extras" => %{"organization" => ""}
               })
    end

    test "api_key emits an api-key header" do
      assert [{"api-key", "key"}] = NativeConfig.auth_headers(:api_key, %{"api_key" => "key"})
    end
  end
end
