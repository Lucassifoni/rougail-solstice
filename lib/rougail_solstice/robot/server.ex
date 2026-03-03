defmodule RougailSolstice.Robot.Server do
  @moduledoc """
  GenServer holding robot state.
  Broadcasts state changes via PubSub.
  Supports session-scoped operation with optional session_id.
  """

  use GenServer

  alias RougailSolstice.Robot.State
  alias RougailSolstice.Sessions.Topics

  @pubsub RougailSolstice.PubSub

  defstruct [:robot_state, :session_id, :image_store]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    init_opts = Keyword.take(opts, [:config, :adapter, :session_id, :image_store])
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  def move_axis(server, axis, delta) do
    GenServer.call(server, {:move_axis, axis, delta})
  end

  def lock_camera(server) do
    GenServer.call(server, :lock_camera)
  end

  def take_picture(server) do
    GenServer.call(server, :take_picture)
  end

  def release_camera(server) do
    GenServer.call(server, :release_camera)
  end

  def reset(server) do
    GenServer.call(server, :reset)
  end

  def set_adapter(server, adapter) do
    GenServer.call(server, {:set_adapter, adapter})
  end

  def subscribe(session_id \\ nil) do
    Phoenix.PubSub.subscribe(@pubsub, Topics.robot(session_id))
  end

  def topic(session_id \\ nil), do: Topics.robot(session_id)

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    adapter = Keyword.get(opts, :adapter)
    session_id = Keyword.get(opts, :session_id)
    image_store = Keyword.get(opts, :image_store)

    result =
      if adapter do
        State.new(config, adapter)
      else
        State.new(config)
      end

    case result do
      {:ok, robot_state} ->
        {:ok,
         %__MODULE__{robot_state: robot_state, session_id: session_id, image_store: image_store}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.robot_state, state}
  end

  def handle_call({:move_axis, axis, delta}, _from, state) do
    case State.move_axis(state.robot_state, axis, delta) do
      {:ok, new_robot_state} ->
        new_state = %{state | robot_state: new_robot_state}
        broadcast(new_state)
        {:reply, {:ok, new_robot_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:lock_camera, _from, state) do
    case State.lock_camera(state.robot_state) do
      {:ok, new_robot_state} ->
        new_state = %{state | robot_state: new_robot_state}
        broadcast(new_state)
        {:reply, {:ok, new_robot_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:take_picture, _from, state) do
    case State.take_picture(state.robot_state) do
      {:ok, new_robot_state, capture} ->
        new_state = %{state | robot_state: new_robot_state}
        broadcast(new_state)
        {:reply, {:ok, new_robot_state, capture}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:release_camera, _from, state) do
    case State.release_camera(state.robot_state) do
      {:ok, new_robot_state} ->
        new_state = %{state | robot_state: new_robot_state}
        broadcast(new_state)
        {:reply, {:ok, new_robot_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:reset, _from, state) do
    {:ok, new_robot_state} = State.new(%{}, state.robot_state.camera_adapter)
    new_state = %{state | robot_state: new_robot_state}
    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:set_adapter, adapter}, _from, state) do
    new_robot_state = %{state.robot_state | camera_adapter: adapter}
    new_state = %{state | robot_state: new_robot_state}
    broadcast(new_state)
    {:reply, {:ok, new_robot_state}, new_state}
  end

  defp broadcast(state) do
    topic = Topics.robot(state.session_id)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:robot_state_changed, state.robot_state})
  end
end
