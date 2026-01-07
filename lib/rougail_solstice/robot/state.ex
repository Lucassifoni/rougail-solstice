defmodule RougailSolstice.Robot.State do
  @moduledoc """
  Complete robot state composing axes and camera.
  All transitions are pure functions.
  """

  alias RougailSolstice.Robot.{Axis, Camera, Capture}
  alias RougailSolstice.Robot.CameraAdapter

  @enforce_keys [:axes, :camera, :camera_adapter]
  defstruct [:axes, :camera, :camera_adapter]

  @type axis_name :: :x | :y | :z
  @type axis_config :: %{min: integer(), max: integer(), initial: integer()}
  @type t :: %__MODULE__{
          axes: %{x: Axis.t(), y: Axis.t(), z: Axis.t()},
          camera: Camera.t(),
          camera_adapter: module()
        }

  @default_adapter CameraAdapter.Virtual

  @default_config %{
    x: %{min: 0, max: 1000, initial: 500},
    y: %{min: 0, max: 1000, initial: 500},
    z: %{min: 0, max: 500, initial: 0}
  }

  @spec new(map(), module()) :: {:ok, t()} | {:error, term()}
  def new(config \\ @default_config, adapter \\ @default_adapter) do
    with {:ok, x} <- create_axis(:x, config),
         {:ok, y} <- create_axis(:y, config),
         {:ok, z} <- create_axis(:z, config) do
      {:ok,
       %__MODULE__{
         axes: %{x: x, y: y, z: z},
         camera: Camera.new(),
         camera_adapter: adapter
       }}
    end
  end

  @spec move_axis(t(), axis_name(), integer()) :: {:ok, t()} | {:error, term()}
  def move_axis(%__MODULE__{} = state, axis_name, delta) when axis_name in [:x, :y, :z] do
    axis = state.axes[axis_name]

    case Axis.move(axis, delta) do
      {:ok, moved_axis} ->
        {:ok, put_in(state.axes[axis_name], moved_axis)}

      {:error, _} = error ->
        error
    end
  end

  @spec set_axis_position(t(), axis_name(), integer()) :: {:ok, t()} | {:error, term()}
  def set_axis_position(%__MODULE__{} = state, axis_name, position)
      when axis_name in [:x, :y, :z] do
    axis = state.axes[axis_name]

    case Axis.set_position(axis, position) do
      {:ok, updated_axis} ->
        {:ok, put_in(state.axes[axis_name], updated_axis)}

      {:error, _} = error ->
        error
    end
  end

  @spec lock_camera(t()) :: {:ok, t()} | {:error, term()}
  def lock_camera(%__MODULE__{} = state) do
    case Camera.lock(state.camera) do
      {:ok, locked_camera} ->
        {:ok, %{state | camera: locked_camera}}

      {:error, _} = error ->
        error
    end
  end

  @spec take_picture(t()) :: {:ok, t(), Capture.t()} | {:error, term()}
  def take_picture(%__MODULE__{} = state) do
    position = get_position(state)

    case Camera.take_picture(state.camera, position, state.camera_adapter) do
      {:ok, updated_camera, capture} ->
        {:ok, %{state | camera: updated_camera}, capture}

      {:error, _} = error ->
        error
    end
  end

  @spec release_camera(t()) :: {:ok, t()} | {:error, term()}
  def release_camera(%__MODULE__{} = state) do
    case Camera.release(state.camera) do
      {:ok, released_camera} ->
        {:ok, %{state | camera: released_camera}}

      {:error, _} = error ->
        error
    end
  end

  @spec get_position(t()) :: %{x: integer(), y: integer(), z: integer()}
  def get_position(%__MODULE__{} = state) do
    %{
      x: state.axes.x.position,
      y: state.axes.y.position,
      z: state.axes.z.position
    }
  end

  defp create_axis(name, config) do
    axis_config = Map.get(config, name, @default_config[name])
    Axis.new(name, axis_config.min, axis_config.max, axis_config.initial)
  end
end
