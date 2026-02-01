defmodule RougailSolstice.Robot.Motor.Command do
  @moduledoc """
  Pure struct representing the desired state of all 3 motor axes.
  Each axis has: enabled (bool), direction (:positive | :negative), speed (0-max_speed).
  """

  @type direction :: :positive | :negative
  @type axis_name :: :axis1 | :axis2 | :axis3
  @type axis_state :: %{enabled: boolean(), direction: direction(), speed: non_neg_integer()}

  @type t :: %__MODULE__{
          axis1: axis_state(),
          axis2: axis_state(),
          axis3: axis_state()
        }

  @axis_names [:axis1, :axis2, :axis3]
  @max_speed 75

  defstruct axis1: %{enabled: false, direction: :positive, speed: 0},
            axis2: %{enabled: false, direction: :positive, speed: 0},
            axis3: %{enabled: false, direction: :positive, speed: 0}

  @spec max_speed() :: non_neg_integer()
  def max_speed, do: @max_speed

  @spec idle() :: t()
  def idle, do: %__MODULE__{}

  @spec set_speed(t(), axis_name(), non_neg_integer()) :: t()
  def set_speed(%__MODULE__{} = cmd, axis, speed)
      when axis in @axis_names and speed >= 0 do
    update_axis(cmd, axis, fn a -> %{a | speed: min(speed, @max_speed)} end)
  end

  @spec set_direction(t(), axis_name(), direction()) :: t()
  def set_direction(%__MODULE__{} = cmd, axis, direction)
      when axis in @axis_names and direction in [:positive, :negative] do
    update_axis(cmd, axis, fn a -> %{a | direction: direction} end)
  end

  @spec enable(t(), axis_name()) :: t()
  def enable(%__MODULE__{} = cmd, axis) when axis in @axis_names do
    update_axis(cmd, axis, fn a -> %{a | enabled: true} end)
  end

  @spec disable(t(), axis_name()) :: t()
  def disable(%__MODULE__{} = cmd, axis) when axis in @axis_names do
    update_axis(cmd, axis, fn a -> %{a | enabled: false} end)
  end

  @spec set_axis(t(), axis_name(), direction(), non_neg_integer()) :: t()
  def set_axis(%__MODULE__{} = cmd, axis, direction, speed)
      when axis in @axis_names and direction in [:positive, :negative] and speed >= 0 do
    Map.put(cmd, axis, %{enabled: true, direction: direction, speed: min(speed, @max_speed)})
  end

  @spec axis_names() :: [axis_name()]
  def axis_names, do: @axis_names

  defp update_axis(cmd, axis, fun) do
    Map.update!(cmd, axis, fun)
  end
end
