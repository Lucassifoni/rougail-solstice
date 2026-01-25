defmodule RougailSolstice.Sessions.SessionManager do
  @moduledoc """
  GenServer tracking open sessions.

  Sessions are ephemeral - they exist only while their processes are running.
  Uses DynamicSupervisor to spawn SessionSupervisors.
  """

  use GenServer

  require Logger

  alias RougailSolstice.OpticalPieces
  alias RougailSolstice.Sessions.SessionSupervisor
  alias RougailSolstice.Sessions.Topics

  @dynamic_sup RougailSolstice.Sessions.DynamicSupervisor

  defstruct [:sessions]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec open_session(integer(), keyword()) :: {:ok, integer()} | {:error, term()}
  def open_session(optical_piece_id, opts \\ []) do
    GenServer.call(__MODULE__, {:open_session, optical_piece_id, opts})
  end

  @spec close_session(integer()) :: :ok | {:error, term()}
  def close_session(session_id) do
    GenServer.call(__MODULE__, {:close_session, session_id})
  end

  @spec get_session(integer()) :: {:ok, map()} | {:error, :not_found}
  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  @spec list_sessions() :: [map()]
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  @spec session_open?(integer()) :: boolean()
  def session_open?(session_id) do
    GenServer.call(__MODULE__, {:session_open?, session_id})
  end

  @spec session_servers(integer()) :: map() | nil
  def session_servers(session_id) do
    if session_open?(session_id) do
      %{
        robot: SessionSupervisor.get_server(session_id, :robot),
        interferometry: SessionSupervisor.get_server(session_id, :interferometry),
        outline: SessionSupervisor.get_server(session_id, :outline),
        image_store: SessionSupervisor.get_server(session_id, :image_store)
      }
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{sessions: %{}}}
  end

  @impl true
  def handle_call({:open_session, optical_piece_id, opts}, _from, state) do
    case OpticalPieces.get_optical_piece(optical_piece_id) do
      nil ->
        {:reply, {:error, :optical_piece_not_found}, state}

      optical_piece ->
        if Map.has_key?(state.sessions, optical_piece_id) do
          {:reply, {:error, :already_open}, state}
        else
          case start_session_supervisor(optical_piece_id, optical_piece, opts) do
            {:ok, pid} ->
              session_info = %{
                optical_piece_id: optical_piece_id,
                optical_piece: optical_piece,
                supervisor_pid: pid,
                started_at: DateTime.utc_now()
              }

              new_sessions = Map.put(state.sessions, optical_piece_id, session_info)

              Logger.info(
                "[SessionManager] Session #{optical_piece_id} opened for #{optical_piece.name}"
              )

              Topics.broadcast(Topics.session_events(), {:session_opened, optical_piece_id})
              {:reply, {:ok, optical_piece_id}, %{state | sessions: new_sessions}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end
    end
  end

  def handle_call({:close_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session_info ->
        DynamicSupervisor.terminate_child(@dynamic_sup, session_info.supervisor_pid)
        new_sessions = Map.delete(state.sessions, session_id)
        Logger.info("[SessionManager] Session #{session_id} closed")
        Topics.broadcast(Topics.session_events(), {:session_closed, session_id})
        {:reply, :ok, %{state | sessions: new_sessions}}
    end
  end

  def handle_call({:get_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      session_info -> {:reply, {:ok, session_info}, state}
    end
  end

  def handle_call(:list_sessions, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.map(fn info ->
        %{
          session_id: info.optical_piece_id,
          optical_piece_name: info.optical_piece.name,
          started_at: info.started_at
        }
      end)

    {:reply, sessions, state}
  end

  def handle_call({:session_open?, session_id}, _from, state) do
    {:reply, Map.has_key?(state.sessions, session_id), state}
  end

  defp start_session_supervisor(session_id, optical_piece, opts) do
    child_spec = {
      SessionSupervisor,
      [
        session_id: session_id,
        optical_piece: optical_piece,
        adapter: Keyword.get(opts, :adapter)
      ]
    }

    DynamicSupervisor.start_child(@dynamic_sup, child_spec)
  end
end
