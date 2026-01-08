# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :rougail_solstice,
  ecto_repos: [RougailSolstice.Repo],
  generators: [timestamp_type: :utc_datetime]

# Interferometry CLI configuration
# mode: :native | :docker
# native: calls dftfringe-cli directly (must be in PATH)
# docker: calls via docker run (image must be built)
config :rougail_solstice, RougailSolstice.Interferometry.CLI,
  mode: :native,
  docker_image: "dftfringe-cli:latest",
  docker_mount_dir: "/data"

# Configures the endpoint
config :rougail_solstice, RougailSolsticeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RougailSolsticeWeb.ErrorHTML, json: RougailSolsticeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: RougailSolstice.PubSub,
  live_view: [signing_salt: "kwUOmGrM"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  rougail_solstice: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  rougail_solstice: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Use EXLA as the default Nx backend
config :nx, default_backend: EXLA.Backend

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
