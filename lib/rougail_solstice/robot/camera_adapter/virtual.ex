defmodule RougailSolstice.Robot.CameraAdapter.Virtual do
  @moduledoc """
  Virtual camera adapter that generates test images for development.
  Looks for sample images in priv/samples/ or generates synthetic ones.
  Preview images are stored in memory via ImageStore.
  """

  require Logger

  @behaviour RougailSolstice.Robot.CameraAdapter

  @samples_dir Application.compile_env(
                 :rougail_solstice,
                 :virtual_samples_dir,
                 "priv/static/samples"
               )
  @capture_dir Application.compile_env(:rougail_solstice, :capture_dir, "/tmp/captures")

  @impl true
  def capture do
    Logger.info("[VirtualCamera] capture() called")
    ensure_capture_dir()
    timestamp = System.unique_integer([:positive])
    output_path = Path.join(@capture_dir, "virtual_capture_#{timestamp}.jpg")

    result =
      case find_sample_image("capture") do
        {:ok, sample} ->
          Logger.debug("[VirtualCamera] Using sample image: #{sample}")
          File.cp!(sample, output_path)
          {:ok, output_path}

        :none ->
          Logger.debug("[VirtualCamera] Generating synthetic capture image")
          generate_test_image_to_file(output_path, 3456, 2304)
      end

    Logger.info("[VirtualCamera] capture() -> #{inspect(result)}")
    result
  end

  @preview_path "/tmp/virtual_preview.jpg"

  @impl true
  def capture_preview do
    Logger.debug("[VirtualCamera] capture_preview() called")

    result =
      case find_sample_image("preview") do
        {:ok, sample} ->
          File.cp!(sample, @preview_path)
          {:ok, @preview_path}

        :none ->
          generate_test_image_to_file(@preview_path, 640, 480)
      end

    case result do
      {:ok, path} ->
        Logger.debug("[VirtualCamera] capture_preview() -> ok: #{path}")

      {:error, reason} ->
        Logger.warning("[VirtualCamera] capture_preview() failed: #{inspect(reason)}")
    end

    result
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
        "capture" -> "#{samples_path}/*.{jpg,JPG,jpeg,JPEG,png,PNG}"
        "preview" -> "#{samples_path}/*.{jpg,JPG,jpeg,JPEG,png,PNG}"
      end

    case Path.wildcard(pattern) do
      [] -> :none
      files -> {:ok, Enum.random(files)}
    end
  end

  defp generate_test_image_to_file(output_path, width, height) do
    args = ["-size", "#{width}x#{height}", "plasma:gray50-gray80", output_path]

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, output_path}
      {output, code} -> {:error, {:convert_failed, code, output}}
    end
  end

  def samples_dir, do: @samples_dir
end
