defmodule RougailSolstice.Interferometry.CLI do
  @moduledoc """
  Wrapper for the dftfringe-cli binary.
  Provides functions to generate DFT previews and run full interferogram analysis.

  Supports two modes configured via application config:
  - :native - calls dftfringe-cli directly (must be in PATH)
  - :docker - calls via docker run with volume mounts
  - :mock - returns dummy data for testing
  """

  require Logger

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
    case mode() do
      :native ->
        run_dft_preview_native(input_path, circle, output_path)

      :docker ->
        run_dft_preview_docker(input_path, circle, output_path)
    end
  end

  defp run_dft_preview_native(input_path, circle, output_path) do
    args = [
      "--input", input_path,
      "--circle", format_circle(circle),
      "--dft-preview",
      "--dft-output", output_path
    ]

    case System.cmd("dftfringe-cli", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path), do: {:ok, output_path}, else: {:error, :output_not_created}

      {output, code} ->
        {:error, {:cli_error, code, output}}
    end
  end

  defp run_dft_preview_docker(input_path, circle, output_path) do
    with_staging_dir(fn staging_dir ->
      input_basename = Path.basename(input_path)
      output_basename = Path.basename(output_path)
      staged_input = Path.join(staging_dir, input_basename)

      File.cp!(input_path, staged_input)

      container_input = Path.join(docker_mount_dir(), input_basename)
      container_output = Path.join(docker_mount_dir(), output_basename)

      args = [
        "--input", container_input,
        "--circle", format_circle(circle),
        "--dft-preview",
        "--dft-output", container_output
      ]

      docker_args =
        ["run", "--rm", "-v", "#{staging_dir}:#{docker_mount_dir()}", docker_image()] ++ args

      Logger.debug("[CLI] Running: docker #{Enum.join(docker_args, " ")}")

      case System.cmd("docker", docker_args, stderr_to_stdout: true) do
        {_output, 0} ->
          staged_output = Path.join(staging_dir, output_basename)

          if File.exists?(staged_output) do
            File.cp!(staged_output, output_path)
            {:ok, output_path}
          else
            {:error, :output_not_created}
          end

        {output, code} ->
          Logger.error("[CLI] Docker command failed (#{code}): #{output}")
          {:error, {:cli_error, code, output}}
      end
    end)
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

    case mode() do
      :mock ->
        {:ok, output} = {:ok, mock_output()}
        {:ok, parsed} = parse_structured_output(output)
        {:ok, Map.merge(parsed, %{wft_path: nil, csv_path: nil})}

      :native ->
        run_analyze_native(input_path, circle, params, center_filter, wft_path, csv_path)

      :docker ->
        run_analyze_docker(input_path, circle, params, center_filter, wft_path, csv_path)
    end
  end

  defp run_analyze_native(input_path, circle, params, center_filter, wft_path, csv_path) do
    args = build_analyze_args(input_path, circle, params, center_filter, wft_path, csv_path)

    case System.cmd("dftfringe-cli", args, stderr_to_stdout: true) do
      {output, 0} ->
        with {:ok, parsed} <- parse_structured_output(output) do
          result =
            parsed
            |> Map.put(:wft_path, if(File.exists?(wft_path), do: wft_path))
            |> Map.put(:csv_path, if(File.exists?(csv_path), do: csv_path))

          {:ok, result}
        end

      {output, code} ->
        {:error, {:cli_error, code, output}}
    end
  end

  defp run_analyze_docker(input_path, circle, params, center_filter, wft_path, csv_path) do
    Logger.info("""
    [CLI] analyze called with:
      input_path: #{input_path}
      circle: cx=#{circle.cx}, cy=#{circle.cy}, r=#{circle.r}
      optical_params: diameter=#{params.diameter}, roc=#{params.roc}, lambda=#{params.lambda}, conic=#{params.conic}, obstruction=#{params[:obstruction]}
      center_filter: #{center_filter}
    """)

    with_staging_dir(fn staging_dir ->
      input_basename = Path.basename(input_path)
      wft_basename = Path.basename(wft_path)
      csv_basename = Path.basename(csv_path)

      staged_input = Path.join(staging_dir, input_basename)
      File.cp!(input_path, staged_input)

      container_input = Path.join(docker_mount_dir(), input_basename)
      container_wft = Path.join(docker_mount_dir(), wft_basename)
      container_csv = Path.join(docker_mount_dir(), csv_basename)

      args = build_analyze_args(container_input, circle, params, center_filter, container_wft, container_csv)

      docker_args =
        ["run", "--rm", "-v", "#{staging_dir}:#{docker_mount_dir()}", docker_image()] ++ args

      Logger.info("[CLI] Running: docker #{Enum.join(docker_args, " ")}")

      case System.cmd("docker", docker_args, stderr_to_stdout: true) do
        {output, 0} ->
          Logger.info("[CLI] Raw output:\n#{output}")

          staged_wft = Path.join(staging_dir, wft_basename)
          staged_csv = Path.join(staging_dir, csv_basename)

          if File.exists?(staged_wft), do: File.cp!(staged_wft, wft_path)
          if File.exists?(staged_csv), do: File.cp!(staged_csv, csv_path)

          with {:ok, parsed} <- parse_structured_output(output) do
            result =
              parsed
              |> Map.put(:wft_path, if(File.exists?(wft_path), do: wft_path))
              |> Map.put(:csv_path, if(File.exists?(csv_path), do: csv_path))

            Logger.info("[CLI] Parsed result: rms=#{result.rms_waves}, pv=#{result.pv_waves}, strehl=#{result.strehl}")
            {:ok, result}
          end

        {output, code} ->
          Logger.error("[CLI] Docker analyze failed (#{code}): #{output}")
          {:error, {:cli_error, code, output}}
      end
    end)
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

  defp with_staging_dir(fun) do
    staging_dir = Path.join(System.tmp_dir!(), "dftfringe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(staging_dir)

    try do
      fun.(staging_dir)
    after
      File.rm_rf(staging_dir)
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

  defp parse_float(str) do
    str |> String.trim() |> Float.parse() |> elem(0)
  end

  defp parse_int(str) do
    str |> String.trim() |> Integer.parse() |> elem(0)
  end
end
