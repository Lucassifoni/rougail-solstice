defmodule RougailSolstice.Interferometry.CLI do
  @moduledoc """
  Wrapper for the dftfringe-cli binary.
  Provides functions to generate DFT previews and run full interferogram analysis.

  Supports two modes configured via application config:
  - :native - calls dftfringe-cli directly (must be in PATH)
  - :docker - calls via docker run with volume mounts
  """

  @type circle :: %{cx: number(), cy: number(), r: number()}
  @type optical_params :: %{
          diameter: number(),
          roc: number(),
          lambda: number(),
          conic: number(),
          obstruction: number() | nil
        }
  @type analysis_result :: %{
          rms_waves: float(),
          pv_waves: float(),
          strehl: float(),
          zernikes_raw: %{integer() => float()},
          zernikes_nulled: %{integer() => float()},
          wft_path: Path.t() | nil,
          csv_path: Path.t() | nil
        }

  @spec dft_preview(Path.t(), circle(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def dft_preview(input_path, circle, output_path) do
    if mode() == :mock do
      mock_dft_preview(output_path)
    else
      run_dft_preview(input_path, circle, output_path)
    end
  end

  defp mock_dft_preview(output_path) do
    File.write!(output_path, "mock dft preview")
    {:ok, output_path}
  end

  defp run_dft_preview(input_path, circle, output_path) do
    {cli_input, cli_output} = translate_paths(input_path, output_path)

    args = [
      "--input",
      cli_input,
      "--circle",
      format_circle(circle),
      "--dft-preview",
      "--dft-output",
      cli_output
    ]

    with {:ok, _output} <- run_cli(args, [input_path, output_path]),
         true <- File.exists?(output_path) do
      {:ok, output_path}
    else
      false -> {:error, :output_not_created}
      {:error, _} = error -> error
    end
  end

  @spec analyze(Path.t(), circle(), optical_params(), keyword()) ::
          {:ok, analysis_result()} | {:error, term()}
  def analyze(input_path, circle, params, opts \\ []) do
    center_filter = Keyword.get(opts, :center_filter, 10)
    output_dir = Keyword.get(opts, :output_dir, System.tmp_dir!())
    basename = Path.basename(input_path, Path.extname(input_path))
    timestamp = System.unique_integer([:positive])

    wft_path = Path.join(output_dir, "#{basename}_#{timestamp}.wft")
    csv_path = Path.join(output_dir, "#{basename}_#{timestamp}_zernikes.csv")

    host_paths = [input_path, wft_path, csv_path]
    [cli_input, cli_wft, cli_csv] = translate_paths(host_paths)

    args = build_analyze_args(cli_input, circle, params, center_filter, cli_wft, cli_csv)

    with {:ok, output} <- run_cli(args, host_paths),
         {:ok, parsed} <- parse_structured_output(output) do
      result =
        parsed
        |> Map.put(:wft_path, if(File.exists?(wft_path), do: wft_path))
        |> Map.put(:csv_path, if(File.exists?(csv_path), do: csv_path))

      {:ok, result}
    end
  end

  @spec parse_structured_output(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_structured_output(output) do
    result =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(
        %{zernikes_raw: %{}, zernikes_nulled: %{}, rms_waves: 0.0, pv_waves: 0.0, strehl: 0.0},
        fn line, acc ->
          case String.split(line, "\t", parts: 2) do
            ["rms_waves", val] ->
              Map.put(acc, :rms_waves, parse_float(val))

            ["pv_waves", val] ->
              Map.put(acc, :pv_waves, parse_float(val))

            ["strehl", val] ->
              Map.put(acc, :strehl, parse_float(val))

            ["zernike_raw_" <> n, val] ->
              put_in(acc, [:zernikes_raw, parse_int(n)], parse_float(val))

            ["zernike_nulled_" <> n, val] ->
              put_in(acc, [:zernikes_nulled, parse_int(n)], parse_float(val))

            _ ->
              acc
          end
        end
      )

    {:ok, result}
  rescue
    e -> {:error, {:parse_error, e}}
  end

  defp build_analyze_args(input, circle, params, center_filter, wft_path, csv_path) do
    base = [
      "--input",
      input,
      "--circle",
      format_circle(circle),
      "--diameter",
      to_string(params.diameter),
      "--roc",
      to_string(params.roc),
      "--lambda",
      to_string(params.lambda),
      "--conic",
      to_string(params.conic),
      "--center-filter",
      to_string(center_filter),
      "--structured-output",
      "--output",
      wft_path,
      "--zernikes",
      csv_path
    ]

    if params[:obstruction] && params.obstruction > 0 do
      base ++ ["--obstruction", to_string(params.obstruction)]
    else
      base
    end
  end

  defp format_circle(%{cx: cx, cy: cy, r: r}) do
    "#{round(cx)},#{round(cy)},#{round(r)}"
  end

  defp config do
    Application.get_env(:rougail_solstice, __MODULE__, [])
  end

  defp mode, do: Keyword.get(config(), :mode, :native)
  defp docker_image, do: Keyword.get(config(), :docker_image, "dftfringe-cli:latest")
  defp docker_mount_dir, do: Keyword.get(config(), :docker_mount_dir, "/data")

  defp translate_paths(paths) when is_list(paths) do
    case mode() do
      :native ->
        paths

      :docker ->
        Enum.map(paths, fn path ->
          Path.join(docker_mount_dir(), Path.basename(path))
        end)
    end
  end

  defp translate_paths(input_path, output_path) do
    [cli_input, cli_output] = translate_paths([input_path, output_path])
    {cli_input, cli_output}
  end

  defp run_cli(args, host_paths) do
    case mode() do
      :mock ->
        {:ok, mock_output()}

      :native ->
        case System.cmd("dftfringe-cli", args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:cli_error, code, output}}
        end

      :docker ->
        volume_mounts = build_volume_mounts(host_paths)

        docker_args =
          ["run", "--rm"] ++ volume_mounts ++ [docker_image(), "dftfringe-cli"] ++ args

        case System.cmd("docker", docker_args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:cli_error, code, output}}
        end
    end
  end

  defp mock_output do
    """
    rms_waves\t0.05
    pv_waves\t0.25
    strehl\t0.95
    zernike_raw_1\t0.001
    zernike_raw_2\t0.002
    zernike_nulled_1\t0.0005
    zernike_nulled_2\t0.001
    """
  end

  defp build_volume_mounts(paths) do
    paths
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn dir ->
      ["-v", "#{dir}:#{docker_mount_dir()}"]
    end)
  end

  defp parse_float(str) do
    str |> String.trim() |> Float.parse() |> elem(0)
  end

  defp parse_int(str) do
    str |> String.trim() |> Integer.parse() |> elem(0)
  end
end
