defmodule RougailSolstice.Robot.CameraAdapter.Canon do
  @moduledoc """
  Canon camera adapter using gphoto2.
  Requires gphoto2 to be installed on the system.
  """

  @behaviour RougailSolstice.Robot.CameraAdapter

  @gphoto2 "gphoto2"
  @capture_dir Application.compile_env(:rougail_solstice, :capture_dir, "/tmp/captures")
  @preview_path "/tmp/preview.jpg"

  @impl true
  def capture do
    ensure_capture_dir()
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = Path.join(@capture_dir, "capture_#{timestamp}.jpg")

    args = [
      "--capture-image-and-download",
      "--filename",
      filename,
      "--force-overwrite"
    ]

    case System.cmd(@gphoto2, args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, filename}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  @impl true
  def capture_preview do
    args = [
      "--capture-preview",
      "--filename",
      @preview_path,
      "--force-overwrite"
    ]

    case System.cmd(@gphoto2, args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, @preview_path}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  @impl true
  def name, do: "Canon (gphoto2)"

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

  def set_config(key, value) do
    case System.cmd(@gphoto2, ["--set-config", "#{key}=#{value}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  def get_config(key) do
    case System.cmd(@gphoto2, ["--get-config", key], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_config(output)}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  def list_config do
    case System.cmd(@gphoto2, ["--list-config"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, code} -> {:error, {:gphoto2_error, code, output}}
    end
  end

  defp ensure_capture_dir do
    File.mkdir_p!(@capture_dir)
  end

  defp parse_cameras(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(2)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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
