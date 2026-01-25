defmodule RougailSolstice.Sessions.SessionSupervisor do
  @moduledoc """
  Per-session supervisor that starts all session-scoped processes.

  Started by SessionManager when a session is opened.
  Supervises: ImageStore, Robot.Server, Interferometry.Server, Outline.Server,
  and optionally Sidecar.Supervisor.
  """

  use Supervisor

  alias RougailSolstice.Robot.CameraAdapter
  alias RougailSolstice.Sessions.Registry, as: SessionRegistry

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Keyword.fetch!(opts, :optical_piece)

    Supervisor.start_link(__MODULE__, opts,
      name: via(session_id, :supervisor)
    )
  end

  def via(session_id, role) do
    {:via, Registry, {SessionRegistry, {session_id, role}}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    optical_piece = Keyword.fetch!(opts, :optical_piece)
    adapter = Keyword.get(opts, :adapter) || CameraAdapter.from_optical_piece(optical_piece)

    children = [
      {RougailSolstice.ImageStore, name: via(session_id, :image_store)},
      {RougailSolstice.Robot.Server,
       name: via(session_id, :robot),
       session_id: session_id,
       adapter: adapter,
       image_store: via(session_id, :image_store)},
      {RougailSolstice.Outline.Server,
       name: via(session_id, :outline),
       session_id: session_id,
       interf_server: via(session_id, :interferometry),
       image_store: via(session_id, :image_store)},
      {RougailSolstice.Interferometry.Server,
       name: via(session_id, :interferometry),
       session_id: session_id,
       robot_server: via(session_id, :robot),
       image_store: via(session_id, :image_store),
       optical_piece: optical_piece}
    ] ++ sidecar_children(session_id)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp sidecar_children(session_id) do
    cli_config = Application.get_env(:rougail_solstice, RougailSolstice.Interferometry.CLI, [])

    if Keyword.get(cli_config, :use_sidecar, false) do
      [{RougailSolstice.Interferometry.Sidecar.Supervisor, session_id: session_id}]
    else
      []
    end
  end

  def get_server(session_id, role) do
    via(session_id, role)
  end
end
