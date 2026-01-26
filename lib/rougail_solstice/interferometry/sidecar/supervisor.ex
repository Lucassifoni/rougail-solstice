defmodule RougailSolstice.Interferometry.Sidecar.Supervisor do
  @moduledoc """
  Supervisor for the DFTFringe analysis sidecar worker.

  Starts a single worker process for full wavefront analysis.
  DFT preview generation is handled by the Nx backend.
  Supports session-scoped operation with optional session_id.
  """

  use Supervisor

  alias RougailSolstice.Interferometry.Sidecar.Worker
  alias RougailSolstice.Sessions.Registry, as: SessionRegistry

  def start_link(opts) do
    session_id = Keyword.get(opts, :session_id)
    name = if session_id, do: via(session_id), else: __MODULE__
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  defp via(session_id) do
    {:via, Registry, {SessionRegistry, {session_id, :sidecar_supervisor}}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id)
    analyze_name = worker_name(session_id, :analyze)

    children = [
      Supervisor.child_spec({Worker, name: analyze_name, role: :analyze},
        id: {:sidecar_analyze, session_id}
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp worker_name(nil, role), do: :"sidecar_#{role}"

  defp worker_name(session_id, role) do
    {:via, Registry, {SessionRegistry, {session_id, :"sidecar_#{role}"}}}
  end

  @spec analyze_worker(integer() | nil) :: atom() | {:via, module(), term()}
  def analyze_worker(session_id \\ nil), do: worker_name(session_id, :analyze)
end
