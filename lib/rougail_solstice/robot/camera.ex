defmodule RougailSolstice.Robot.Camera do
  @moduledoc """
  Camera state machine.

  States: :idle -> :locked -> :idle

  While locked, multiple pictures can be taken.
  """

  alias RougailSolstice.Robot.Capture

  defstruct status: :idle, last_capture: nil

  @type status :: :idle | :locked
  @type t :: %__MODULE__{
          status: status(),
          last_capture: Capture.t() | nil
        }

  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @spec lock(t()) :: {:ok, t()} | {:error, term()}
  def lock(%__MODULE__{status: :idle} = camera) do
    {:ok, %{camera | status: :locked}}
  end

  def lock(%__MODULE__{status: :locked}) do
    {:error, :already_locked}
  end

  @spec take_picture(t(), %{x: integer(), y: integer(), z: integer()}, module()) ::
          {:ok, t(), Capture.t()} | {:error, term()}
  def take_picture(%__MODULE__{status: :locked} = camera, position, adapter) do
    case adapter.capture() do
      {:ok, image_path} ->
        capture = Capture.new(position, image_path)
        {:ok, %{camera | last_capture: capture}, capture}

      {:error, _} = error ->
        error
    end
  end

  def take_picture(%__MODULE__{status: :idle}, _position, _adapter) do
    {:error, :camera_not_locked}
  end

  @spec release(t()) :: {:ok, t()} | {:error, term()}
  def release(%__MODULE__{status: :locked} = camera) do
    {:ok, %{camera | status: :idle}}
  end

  def release(%__MODULE__{status: :idle}) do
    {:error, :camera_not_locked}
  end
end
