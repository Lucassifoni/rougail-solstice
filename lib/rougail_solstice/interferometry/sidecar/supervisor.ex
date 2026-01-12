defmodule RougailSolstice.Interferometry.Sidecar.Supervisor do
  @moduledoc """
  Supervisor for DFTFringe sidecar workers.

  Starts two worker processes:
  - :sidecar_preview - handles DFT preview generation
  - :sidecar_analyze - handles full wavefront analysis

  Both workers are restarted independently on failure.
  """

  use Supervisor

  alias RougailSolstice.Interferometry.Sidecar.Worker

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Supervisor.child_spec({Worker, name: :sidecar_preview, role: :preview},
        id: :sidecar_preview
      ),
      Supervisor.child_spec({Worker, name: :sidecar_analyze, role: :analyze},
        id: :sidecar_analyze
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec preview_worker() :: atom()
  def preview_worker, do: :sidecar_preview

  @spec analyze_worker() :: atom()
  def analyze_worker, do: :sidecar_analyze
end
