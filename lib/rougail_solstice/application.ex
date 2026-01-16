defmodule RougailSolstice.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
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
        RougailSolstice.ImageStore,
        RougailSolstice.Outline.Server,
        RougailSolstice.Robot.Server
      ] ++
        sidecar_children() ++
        dft_pool_children() ++
        [
          RougailSolstice.Interferometry.Server,
          RougailSolsticeWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: RougailSolstice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp sidecar_children do
    cli_config = Application.get_env(:rougail_solstice, RougailSolstice.Interferometry.CLI, [])

    if Keyword.get(cli_config, :use_sidecar, false) do
      [RougailSolstice.Interferometry.Sidecar.Supervisor]
    else
      []
    end
  end

  defp dft_pool_children do
    cli_config = Application.get_env(:rougail_solstice, RougailSolstice.Interferometry.CLI, [])

    if Keyword.get(cli_config, :dft_backend) == :pool do
      pool_size = Keyword.get(cli_config, :dft_pool_size, 10)
      dft_size = Keyword.get(cli_config, :dft_size, 512)

      [
        {RougailSolstice.Interferometry.DFT.Pool,
         name: RougailSolstice.Interferometry.DFT.Pool,
         pool_size: pool_size,
         dft_size: dft_size,
         callback: &dft_pool_callback/1}
      ]
    else
      []
    end
  end

  defp dft_pool_callback(result) do
    Phoenix.PubSub.broadcast(
      RougailSolstice.PubSub,
      "dft_pool:results",
      {:dft_preview_result, result}
    )
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RougailSolsticeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
