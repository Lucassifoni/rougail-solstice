defmodule RougailSolstice.Robot.CameraAdapter.Canon do
  @moduledoc """
  Canon camera adapter using gphoto2.
  Requires gphoto2 to be installed on the system.
  Returns binary data directly to avoid filesystem I/O.

  Can be used as a module (selects first available camera) or as a struct
  with a specific port for multi-camera setups.
  """

  @behaviour RougailSolstice.Robot.CameraAdapter

  defstruct [:port, :model]

  @type t :: %__MODULE__{
          port: String.t() | nil,
          model: String.t() | nil
        }

  @gphoto2 "gphoto2"

  @impl true
  def capture, do: do_capture(nil)

  def capture(%__MODULE__{port: port}), do: do_capture(port)

  defp do_capture(port) do
    base_args = [
      "--capture-image-and-download",
      "--stdout"
    ]

    args = add_port_args(base_args, port)

    case System.cmd(@gphoto2, args, stderr_to_stdout: false) do
      {binary, 0} when byte_size(binary) > 0 ->
        {:ok, {:binary, binary, "image/jpeg"}}

      {_, 0} ->
        {:error, :empty_capture}

      {output, code} ->
        {:error, {:gphoto2_error, code, output}}
    end
  end

  @impl true
  def capture_preview, do: do_capture_preview(nil)

  def capture_preview(%__MODULE__{port: port}), do: do_capture_preview(port)

  defp do_capture_preview(port) do
    base_args = [
      "--capture-preview",
      "--stdout"
    ]

    args = add_port_args(base_args, port)

    case System.cmd(@gphoto2, args, stderr_to_stdout: false) do
      {binary, 0} when byte_size(binary) > 0 ->
        {:ok, {:binary, binary, "image/jpeg"}}

      {_, 0} ->
        {:error, :empty_preview}

      {output, code} ->
        {:error, {:gphoto2_error, code, output}}
    end
  end

  @impl true
  def name, do: "Canon (gphoto2)"

  def name(%__MODULE__{model: nil, port: port}), do: "Canon @ #{port}"
  def name(%__MODULE__{model: model}), do: model

  @spec detect_cameras() :: {:ok, [t()]} | {:error, term()}
  def detect_cameras do
    case System.cmd(@gphoto2, ["--auto-detect"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_cameras_to_structs(output)}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  def detect do
    case System.cmd(@gphoto2, ["--auto-detect"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_cameras(output)}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  def available? do
    case System.cmd("which", [@gphoto2], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  def set_config(key, value, port \\ nil) do
    base_args = ["--set-config", "#{key}=#{value}"]
    args = add_port_args(base_args, port)

    case System.cmd(@gphoto2, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  def get_config(key, port \\ nil) do
    base_args = ["--get-config", key]
    args = add_port_args(base_args, port)

    case System.cmd(@gphoto2, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_config(output)}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  def list_config(port \\ nil) do
    base_args = ["--list-config"]
    args = add_port_args(base_args, port)

    case System.cmd(@gphoto2, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  defp add_port_args(args, nil), do: args
  defp add_port_args(args, port), do: ["--port", port | args]

  defp parse_cameras(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(2)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_cameras_to_structs(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(2)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_camera_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_camera_line(line) do
    case Regex.run(~r/^(.+?)\s+(usb:\d+,\d+)$/, line) do
      [_, model, port] ->
        %__MODULE__{port: port, model: String.trim(model)}

      _ ->
        nil
    end
  end

  defp parse_config(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end
end
