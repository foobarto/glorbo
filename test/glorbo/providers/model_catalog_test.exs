defmodule Glorbo.Providers.ModelCatalogTest do
  use Glorbo.DataCase, async: false

  alias Glorbo.CLI.Registry.Provider
  alias Glorbo.ProviderModel
  alias Glorbo.Providers.ModelCatalog

  defp tmp_base(ctx) do
    root =
      Path.join(
        System.tmp_dir!(),
        "glorbo-model-catalog-#{ctx.test |> inspect() |> String.replace(~r/\W/, "")}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([root, "cache", "providers"]))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp openai_provider(name \\ "openai") do
    %Provider{
      name: name,
      kind: :native,
      endpoint: "https://api.openai.test/v1",
      auth: :bearer,
      model_list: %{shape: :openai, path: "/v1/models"},
      source: :test,
      source_file: "<test>"
    }
  end

  defp ollama_provider(name \\ "ollama") do
    %Provider{
      name: name,
      kind: :native,
      endpoint: "http://localhost:11434",
      auth: :none,
      model_list: %{shape: :ollama, path: "/api/tags"},
      source: :test,
      source_file: "<test>"
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  describe "rows_from_response/3 — openai shape" do
    test "extracts model_id + context_window + family from each data[] row" do
      body =
        Jason.encode!(%{
          "data" => [
            %{"id" => "gpt-4", "context_window" => 8192, "owned_by" => "openai"},
            %{"id" => "gpt-4o-mini", "context_length" => 128_000, "family" => "gpt"}
          ]
        })

      assert {:ok, rows} = ModelCatalog.rows_from_response(openai_provider(), body, now())
      assert length(rows) == 2

      [first, second] = rows
      assert first.alias == "openai"
      assert first.model_id == "gpt-4"
      assert first.context_window == 8192
      assert first.family == "openai"
      assert is_binary(first.raw_json)
      assert second.context_window == 128_000
      assert second.family == "gpt"
    end

    test "returns empty list when data[] is empty" do
      body = Jason.encode!(%{"data" => []})
      assert {:ok, []} = ModelCatalog.rows_from_response(openai_provider(), body, now())
    end

    test "returns :invalid_openai_models_shape when rows lack id" do
      body = Jason.encode!(%{"data" => [%{"name" => "gpt-4"}]})

      assert {:error, :invalid_openai_models_shape} =
               ModelCatalog.rows_from_response(openai_provider(), body, now())
    end

    test "returns :missing_models_list when data key is missing" do
      body = Jason.encode!(%{"other" => []})

      assert {:error, :missing_models_list} =
               ModelCatalog.rows_from_response(openai_provider(), body, now())
    end

    test "returns {:invalid_json, _} on malformed JSON" do
      assert {:error, {:invalid_json, _}} =
               ModelCatalog.rows_from_response(openai_provider(), "not-json", now())
    end
  end

  describe "rows_from_response/3 — ollama shape" do
    test "extracts models[].name + details.family" do
      body =
        Jason.encode!(%{
          "models" => [
            %{
              "name" => "llama3:latest",
              "context_window" => 8192,
              "details" => %{"family" => "llama"}
            }
          ]
        })

      assert {:ok, [row]} = ModelCatalog.rows_from_response(ollama_provider(), body, now())
      assert row.alias == "ollama"
      assert row.model_id == "llama3:latest"
      assert row.context_window == 8192
      assert row.family == "llama"
    end

    test "returns :invalid_ollama_models_shape when rows lack name" do
      body = Jason.encode!(%{"models" => [%{"id" => "x"}]})

      assert {:error, :invalid_ollama_models_shape} =
               ModelCatalog.rows_from_response(ollama_provider(), body, now())
    end
  end

  describe "read_cache_rows/2" do
    test "returns [] when cache file is missing", ctx do
      base = tmp_base(ctx)

      assert {:ok, []} =
               ModelCatalog.read_cache_rows(base, openai_provider()) |> elevate_missing_to_ok()
    end

    test "decodes cache file contents into rows", ctx do
      base = tmp_base(ctx)
      cache_path = Path.join([base, "cache", "providers", "openai.json"])

      File.write!(cache_path, Jason.encode!(%{"data" => [%{"id" => "gpt-5"}]}))

      assert {:ok, [row]} = ModelCatalog.read_cache_rows(base, openai_provider())
      assert row.model_id == "gpt-5"
      assert %DateTime{} = row.refreshed_at
    end

    test "refuses cache files that are not regular files", ctx do
      base = tmp_base(ctx)
      cache_path = Path.join([base, "cache", "providers", "openai.json"])

      # create a symlink pointing at a regular file; File.lstat follows symlinks and reports :symlink
      target = Path.join([base, "real.json"])
      File.write!(target, Jason.encode!(%{"data" => []}))
      File.ln_s!(target, cache_path)

      assert {:error, {:not_regular_file, :symlink}} =
               ModelCatalog.read_cache_rows(base, openai_provider())
    end
  end

  describe "rebuild_projection_from_cache/2" do
    test "rebuilds provider_models from on-disk cache (bit-for-bit)", ctx do
      base = tmp_base(ctx)

      File.write!(
        Path.join([base, "cache", "providers", "openai.json"]),
        Jason.encode!(%{"data" => [%{"id" => "gpt-5"}, %{"id" => "gpt-4o"}]})
      )

      File.write!(
        Path.join([base, "cache", "providers", "ollama.json"]),
        Jason.encode!(%{"models" => [%{"name" => "llama3:latest"}]})
      )

      # Seed a stale row that should be wiped.
      Glorbo.Repo.insert_all(ProviderModel, [
        %{
          alias: "openai",
          model_id: "gpt-obsolete",
          raw_json: "{}",
          refreshed_at: now()
        }
      ])

      assert :ok =
               ModelCatalog.rebuild_projection_from_cache(base,
                 providers: [openai_provider(), ollama_provider()]
               )

      rows = Glorbo.Repo.all(ProviderModel)
      ids = rows |> Enum.map(& &1.model_id) |> Enum.sort()
      assert ids == ["gpt-4o", "gpt-5", "llama3:latest"]
    end

    test "empty cache → empty projection", ctx do
      base = tmp_base(ctx)

      Glorbo.Repo.insert_all(ProviderModel, [
        %{
          alias: "openai",
          model_id: "gpt-obsolete",
          raw_json: "{}",
          refreshed_at: now()
        }
      ])

      assert :ok =
               ModelCatalog.rebuild_projection_from_cache(base, providers: [openai_provider()])

      assert Glorbo.Repo.aggregate(ProviderModel, :count) == 0
    end
  end

  describe "GenServer refresh_provider/2" do
    setup ctx do
      base = tmp_base(ctx)
      me = self()

      {:ok, base: base, me: me}
    end

    defp start_catalog!(opts) do
      # Use a pid rather than a generated atom name — avoids credo's
      # warn-on-runtime-atom-creation. GenServer.server() accepts pids.
      id = {ModelCatalog, System.unique_integer([:positive])}
      opts = Keyword.put(opts, :name, nil)
      pid = start_supervised!(Supervisor.child_spec({ModelCatalog, opts}, id: id))
      Ecto.Adapters.SQL.Sandbox.allow(Glorbo.Repo, self(), pid)
      pid
    end

    test "happy path — persists cache + populates projection + returns :ready", ctx do
      request_fun = fn _req ->
        {:ok, %{status: 200, body: Jason.encode!(%{"data" => [%{"id" => "gpt-5"}]})}}
      end

      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: request_fun,
          credentials_read_fun: fn _ -> {:ok, ~s(api_key = "sk-test")} end
        )

      assert {:ok, %{status: :ready, model_count: 1}} =
               ModelCatalog.refresh_provider("openai", name)

      assert File.exists?(Path.join([ctx.base, "cache", "providers", "openai.json"]))
      assert [%ProviderModel{model_id: "gpt-5"}] = Glorbo.Repo.all(ProviderModel)
    end

    test "401 → :auth status with no cache write", ctx do
      request_fun = fn _req -> {:ok, %{status: 401, body: "unauthorized"}} end

      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: request_fun,
          credentials_read_fun: fn _ -> {:ok, ~s(api_key = "sk-test")} end
        )

      assert {:error, {{:http_status, 401, _}, %{status: :auth}}} =
               ModelCatalog.refresh_provider("openai", name)

      refute File.exists?(Path.join([ctx.base, "cache", "providers", "openai.json"]))
    end

    test "econnrefused → :unreachable", ctx do
      request_fun = fn _req -> {:error, :econnrefused} end

      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: request_fun,
          credentials_read_fun: fn _ -> {:ok, ~s(api_key = "sk-test")} end
        )

      assert {:error, {{:http_request_failed, :econnrefused}, %{status: :unreachable}}} =
               ModelCatalog.refresh_provider("openai", name)
    end

    test "timeout → :stale", ctx do
      request_fun = fn _req -> {:error, :timeout} end

      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: request_fun,
          credentials_read_fun: fn _ -> {:ok, ~s(api_key = "sk-test")} end
        )

      assert {:error, {{:http_request_failed, :timeout}, %{status: :stale}}} =
               ModelCatalog.refresh_provider("openai", name)
    end

    test "malformed JSON → :shape", ctx do
      request_fun = fn _req -> {:ok, %{status: 200, body: "not-json"}} end

      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: request_fun,
          credentials_read_fun: fn _ -> {:ok, ~s(api_key = "sk-test")} end
        )

      assert {:error, {{:invalid_json, _}, %{status: :shape}}} =
               ModelCatalog.refresh_provider("openai", name)
    end

    test "missing api_key → :auth", ctx do
      request_fun = fn _req -> flunk("should not reach HTTP layer") end

      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: request_fun,
          credentials_read_fun: fn _ -> {:error, :enoent} end
        )

      assert {:error, {{:missing_api_key, "openai"}, %{status: :auth}}} =
               ModelCatalog.refresh_provider("openai", name)
    end

    test "unknown provider returns :unknown_provider", ctx do
      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: fn _ -> {:error, :boom} end,
          credentials_read_fun: fn _ -> {:ok, ""} end
        )

      assert {:error, :unknown_provider} = ModelCatalog.refresh_provider("nope", name)
    end

    test "model_known?/3 distinguishes :known / :unknown / :no_cache", ctx do
      name =
        start_catalog!(
          base: ctx.base,
          registry_name: stub_registry([openai_provider()]),
          request_fun: fn _req ->
            {:ok, %{status: 200, body: Jason.encode!(%{"data" => [%{"id" => "gpt-5"}]})}}
          end,
          credentials_read_fun: fn _ -> {:ok, ~s(api_key = "sk-test")} end
        )

      assert :no_cache = ModelCatalog.model_known?("openai", "gpt-5", name)

      assert {:ok, _} = ModelCatalog.refresh_provider("openai", name)

      assert :known = ModelCatalog.model_known?("openai", "gpt-5", name)
      assert :unknown = ModelCatalog.model_known?("openai", "ghost", name)
      assert :no_cache = ModelCatalog.model_known?("other", "x", name)
    end
  end

  # Glorbo.CLI.Registry.list(server) does `Agent.get(server, &Map.values/1)`
  # and Agent.get/2 accepts either a name or a pid — returning a pid keeps
  # this helper free of runtime atom creation.
  defp stub_registry(providers) do
    state = Map.new(providers, &{&1.name, &1})
    {:ok, pid} = Agent.start_link(fn -> state end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  defp elevate_missing_to_ok({:error, :enoent}), do: {:ok, []}
  defp elevate_missing_to_ok(other), do: other
end
