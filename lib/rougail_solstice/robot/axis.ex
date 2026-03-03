defmodule RougailSolstice.Robot.Axis do
  @moduledoc """
  Represents a single robot axis with position bounds.
  All transitions are pure functions returning {:ok, axis} | {:error, reason}.
  """

  @enforce_keys [:name, :position, :min, :max]
  defstruct [:name, :position, :min, :max]

  @type t :: %__MODULE__{
          name: atom(),
          position: integer(),
          min: integer(),
          max: integer()
        }

  @spec new(atom(), integer(), integer(), integer()) :: {:ok, t()} | {:error, term()}
  def new(name, min, max, initial \\ nil) do
    initial = initial || min

    cond do
      min > max ->
        {:error, :invalid_bounds}

      initial < min or initial > max ->
        {:error, :initial_out_of_bounds}

      true ->
        {:ok, %__MODULE__{name: name, position: initial, min: min, max: max}}
    end
  end

  @spec move(t(), integer()) :: {:ok, t()} | {:error, term()}
  def move(%__MODULE__{} = axis, delta) do
    set_position(axis, axis.position + delta)
  end

  defp set_position(%__MODULE__{} = axis, position) do
    cond do
      position < axis.min ->
        {:error, :below_minimum}

      position > axis.max ->
        {:error, :above_maximum}

      true ->
        {:ok, %{axis | position: position}}
    end
  end
end
