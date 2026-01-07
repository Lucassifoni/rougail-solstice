defmodule RougailSolstice.Robot.Server do
  @moduledoc """
  GenServer holding robot state.
  Broadcasts state changes via PubSub.
  """

  use GenServer

  alias RougailSolstice.Robot.State

  @pubsub RougailSolstice.PubSub
  @topic "robot:state"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    init_opts = Keyword.take(opts, [:config, :adapter])
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  def move_axis(server \\ __MODULE__, axis, delta) do
    GenServer.call(server, {:move_axis, axis, delta})
  end

  def set_axis_position(server \\ __MODULE__, axis, position) do
    GenServer.call(server, {:set_axis_position, axis, position})
  end

  def lock_camera(server \\ __MODULE__) do
    GenServer.call(server, :lock_camera)
  end

  def take_picture(server \\ __MODULE__) do
    GenServer.call(server, :take_picture)
  end

  def release_camera(server \\ __MODULE__) do
    GenServer.call(server, :release_camera)
  end

  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  def set_adapter(server \\ __MODULE__, adapter) do
    GenServer.call(server, {:set_adapter, adapter})
  end

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  def topic, do: @topic

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    adapter = Keyword.get(opts, :adapter)

    result =
      if adapter do
        State.new(config, adapter)
      else
        State.new(config)
      end

    case result do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:move_axis, axis, delta}, _from, state) do
    case State.move_axis(state, axis, delta) do
      {:ok, new_state} ->
        broadcast(new_state)
        {:reply, {:ok, new_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:set_axis_position, axis, position}, _from, state) do
    case State.set_axis_position(state, axis, position) do
      {:ok, new_state} ->
        broadcast(new_state)
        {:reply, {:ok, new_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:lock_camera, _from, state) do
    case State.lock_camera(state) do
      {:ok, new_state} ->
        broadcast(new_state)
        {:reply, {:ok, new_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:take_picture, _from, state) do
    case State.take_picture(state) do
      {:ok, new_state, capture} ->
        broadcast(new_state)
        {:reply, {:ok, new_state, capture}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:release_camera, _from, state) do
    case State.release_camera(state) do
      {:ok, new_state} ->
        broadcast(new_state)
        {:reply, {:ok, new_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:reset, _from, state) do
    {:ok, new_state} = State.new(%{}, state.camera_adapter)
    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:set_adapter, adapter}, _from, state) do
    new_state = %{state | camera_adapter: adapter}
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:robot_state_changed, state})
  end
end
