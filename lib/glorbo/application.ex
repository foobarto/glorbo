defmodule Glorbo.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Glorbo.Repo,
      {DNSCluster, query: Application.get_env(:glorbo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Glorbo.PubSub},
      GlorboWeb.Telemetry,
      Glorbo.ContainerManager,
      {DynamicSupervisor, name: Glorbo.CompanySupervisor, strategy: :one_for_one},
      GlorboWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Glorbo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    GlorboWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
