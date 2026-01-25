defmodule RougailSolsticeWeb.Router do
  use RougailSolsticeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RougailSolsticeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RougailSolsticeWeb do
    pipe_through :browser

    live "/", SessionsLive.Index, :index

    live "/optical-pieces", OpticalPiecesLive.Index, :index
    live "/optical-pieces/new", OpticalPiecesLive.Index, :new
    live "/optical-pieces/:id/edit", OpticalPiecesLive.Index, :edit

    live "/sessions/:session_id/robot", RobotLive

    get "/sessions/:session_id/images/:key", ImageController, :show_session
  end

  # Other scopes may use custom stacks.
  # scope "/api", RougailSolsticeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:rougail_solstice, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RougailSolsticeWeb.Telemetry
    end
  end
end
