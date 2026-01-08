defmodule RougailSolstice.Robot.CameraAdapter.Virtual do
  @moduledoc """
  Virtual camera adapter that generates test images for development.
  Looks for sample images in priv/samples/ or generates synthetic ones.
  """

  @behaviour RougailSolstice.Robot.CameraAdapter

  @samples_dir Application.compile_env(:rougail_solstice, :virtual_samples_dir, "priv/samples")
  @capture_dir Application.compile_env(:rougail_solstice, :capture_dir, "/tmp/captures")
  @preview_path "/tmp/virtual_preview.jpg"

  @impl true
  def capture do
    ensure_capture_dir()
    timestamp = System.unique_integer([:positive])
    output_path = Path.join(@capture_dir, "virtual_capture_#{timestamp}.jpg")

    case find_sample_image("capture") do
      {:ok, sample} ->
        File.cp!(sample, output_path)
        {:ok, output_path}

      :none ->
        generate_test_image(output_path, 3456, 2304)
    end
  end

  @impl true
  def capture_preview do
    case find_sample_image("preview") do
      {:ok, sample} ->
        File.cp!(sample, @preview_path)
        {:ok, @preview_path}

      :none ->
        generate_test_image(@preview_path, 640, 480)
    end
  end

  @impl true
  def name, do: "Virtual"

  defp ensure_capture_dir do
    File.mkdir_p!(@capture_dir)
  end

  defp find_sample_image(type) do
    samples_path = Path.expand(@samples_dir, File.cwd!())

    pattern =
      case type do
        "capture" -> "#{samples_path}/capture*.{jpg,jpeg,png}"
        "preview" -> "#{samples_path}/preview*.{jpg,jpeg,png}"
      end

    case Path.wildcard(pattern) do
      [] -> :none
      files -> {:ok, Enum.random(files)}
    end
  end

  defp generate_test_image(output_path, width, height) do
    args = [
      "-size",
      "#{width}x#{height}",
      "plasma:gray50-gray80",
      "-blur",
      "0x2",
      output_path
    ]

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, output_path}
      {output, code} -> {:error, {:convert_failed, code, output}}
    end
  end

  def samples_dir, do: @samples_dir
end
