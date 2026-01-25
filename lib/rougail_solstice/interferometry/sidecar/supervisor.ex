defmodule RougailSolstice.Interferometry.Sidecar.Supervisor do
  @moduledoc """
  Supervisor for DFTFringe sidecar workers.

  Starts two worker processes:
  - :sidecar_preview - handles DFT preview generation
  - :sidecar_analyze - handles full wavefront analysis

  Both workers are restarted independently on failure.
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

    preview_name = worker_name(session_id, :preview)
    analyze_name = worker_name(session_id, :analyze)

    children = [
      Supervisor.child_spec({Worker, name: preview_name, role: :preview},
        id: {:sidecar_preview, session_id}
      ),
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

  @spec preview_worker(integer() | nil) :: atom() | {:via, module(), term()}
  def preview_worker(session_id \\ nil), do: worker_name(session_id, :preview)

  @spec analyze_worker(integer() | nil) :: atom() | {:via, module(), term()}
  def analyze_worker(session_id \\ nil), do: worker_name(session_id, :analyze)
end
