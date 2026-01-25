defmodule RougailSolstice.Robot.Capture do
  @moduledoc """
  Represents a captured image with timestamp and axis positions at capture time.
  Stores image data as in-memory binary.
  """

  @enforce_keys [:timestamp, :position, :image_binary, :content_type]
  defstruct [:timestamp, :position, :image_binary, :content_type]

  @type t :: %__MODULE__{
          timestamp: DateTime.t(),
          position: %{x: integer(), y: integer(), z: integer()},
          image_binary: binary(),
          content_type: String.t()
        }

  @spec new(%{x: integer(), y: integer(), z: integer()}, binary(), String.t()) :: t()
  def new(position, image_binary, content_type) do
    %__MODULE__{
      timestamp: DateTime.utc_now(),
      position: position,
      image_binary: image_binary,
      content_type: content_type
    }
  end
end
