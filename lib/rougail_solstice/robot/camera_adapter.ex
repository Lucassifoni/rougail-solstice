defmodule RougailSolstice.Robot.CameraAdapter do
  @moduledoc """
  Behaviour for camera adapters.
  Adapters can be either modules (stateless) or structs (with configuration like port).
  """

  alias __MODULE__.{Virtual, Canon}

  @type capture_result ::
          {:ok, Path.t()}
          | {:ok, {:binary, binary(), content_type :: String.t()}}
          | {:error, term()}
  @type adapter :: module() | struct()

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
  Returns the list of all registered camera adapter modules.
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
  Returns the display name for an adapter (module or struct).
  """
  def adapter_name(%module{} = adapter) do
    if function_exported?(module, :name, 1) do
      module.name(adapter)
    else
      module |> Module.split() |> List.last()
    end
  end

  def adapter_name(adapter) when is_atom(adapter) do
    if function_exported?(adapter, :name, 0) do
      adapter.name()
    else
      adapter |> Module.split() |> List.last()
    end
  end

  @doc """
  Captures using the given adapter (module or struct).
  """
  def capture(%module{} = adapter) do
    module.capture(adapter)
  end

  def capture(adapter) when is_atom(adapter) do
    adapter.capture()
  end

  @doc """
  Captures preview using the given adapter (module or struct).
  """
  def capture_preview(%module{} = adapter) do
    module.capture_preview(adapter)
  end

  def capture_preview(adapter) when is_atom(adapter) do
    adapter.capture_preview()
  end

  @doc """
  Creates an adapter from an optical piece's camera configuration.
  """
  def from_optical_piece(%{camera_port: nil}), do: Virtual

  def from_optical_piece(%{camera_port: port, camera_model: model}) do
    %Canon{port: port, model: model}
  end

  def from_optical_piece(_), do: Virtual
end
