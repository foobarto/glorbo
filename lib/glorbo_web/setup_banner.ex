defmodule GlorboWeb.SetupBanner do
  @moduledoc """
  One-shot first-run banner for `mix phx.server` development boots.

  Secret-bearing URLs must not be printed from `runtime.exs`, which is loaded
  by unrelated Mix tasks. This child runs after the Endpoint and prints only
  when Phoenix has explicitly enabled endpoint serving.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  @spec start_link() :: :ignore
  def start_link do
    if print_banner?() do
      IO.puts("\n  glorbo dashboard (first-run setup): " <> dashboard_url() <> "\n")
    end

    :ignore
  end

  @doc false
  @spec print_banner?() :: boolean()
  def print_banner? do
    Application.get_env(:glorbo, :dev_setup_banner, false) and endpoint_serving?() and
      bootstrap?()
  end

  defp endpoint_serving? do
    Application.get_env(:phoenix, :serve_endpoints, false) or
      Application.get_env(:glorbo, GlorboWeb.Endpoint, []) |> Keyword.get(:server, false)
  end

  defp bootstrap? do
    not match?(
      hash when is_binary(hash) and hash != "",
      Application.get_env(:glorbo, :director_password_hash)
    )
  end

  defp dashboard_url do
    endpoint = Application.get_env(:glorbo, GlorboWeb.Endpoint, [])
    port = endpoint |> Keyword.get(:http, []) |> Keyword.get(:port, 4000)

    Glorbo.CLI.Lifecycle.Banner.dashboard_url(
      "http://127.0.0.1:#{port}",
      Application.get_env(:glorbo, :director_password_hash),
      Application.get_env(:glorbo, :dashboard_token)
    )
  end
end
