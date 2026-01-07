defmodule RougailSolstice.Robot.CameraAdapter do
  @moduledoc """
  Behaviour for camera adapters.
  Adapters are stateless - they perform capture operations and return file paths.
  """

  alias __MODULE__.{Virtual, Canon}

  @type capture_result :: {:ok, Path.t()} | {:error, term()}

  @adapters [Virtual, Canon]

  @doc """
  Captures a full-resolution still image.
  Returns the path to the captured image file.
  """
  @callback capture() :: capture_result()

  @doc """
  Captures a low-resolution preview frame (live view).
  Returns the path to the preview image file.
  Used for real-time viewfinder display.
  """
  @callback capture_preview() :: capture_result()

  @doc """
  Returns a human-readable name for the adapter.
  """
  @callback name() :: String.t()

  @optional_callbacks [name: 0]

  @doc """
  Returns the list of all registered camera adapters.
  """
  def all, do: @adapters

  @doc """
  Returns the adapter module for a given name.
  """
  def get_by_name(name) do
    Enum.find(@adapters, fn adapter ->
      adapter_name(adapter) == name
    end)
  end

  @doc """
  Returns the display name for an adapter module.
  """
  def adapter_name(adapter) do
    if function_exported?(adapter, :name, 0) do
      adapter.name()
    else
      adapter |> Module.split() |> List.last()
    end
  end
end
