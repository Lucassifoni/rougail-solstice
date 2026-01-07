defmodule RougailSolstice.Robot.Capture do
  @moduledoc """
  Represents a captured image with timestamp and axis positions at capture time.
  """

  @enforce_keys [:timestamp, :position, :image_path]
  defstruct [:timestamp, :position, :image_path]

  @type t :: %__MODULE__{
          timestamp: DateTime.t(),
          position: %{x: integer(), y: integer(), z: integer()},
          image_path: Path.t()
        }

  @spec new(%{x: integer(), y: integer(), z: integer()}, Path.t()) :: t()
  def new(position, image_path) do
    %__MODULE__{
      timestamp: DateTime.utc_now(),
      position: position,
      image_path: image_path
    }
  end
end
