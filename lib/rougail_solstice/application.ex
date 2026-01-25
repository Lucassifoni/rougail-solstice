defmodule RougailSolstice.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        RougailSolsticeWeb.Telemetry,
        RougailSolstice.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:rougail_solstice, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster,
         query: Application.get_env(:rougail_solstice, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: RougailSolstice.PubSub},
        {Registry, keys: :unique, name: RougailSolstice.Sessions.Registry},
        {DynamicSupervisor,
         name: RougailSolstice.Sessions.DynamicSupervisor, strategy: :one_for_one},
        RougailSolstice.Sessions.SessionManager,
        RougailSolsticeWeb.Endpoint
      ]

    opts = [strategy: :one_for_one, name: RougailSolstice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RougailSolsticeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    System.get_env("RELEASE_NAME") == nil
  end
end
