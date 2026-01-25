defmodule RougailSolstice.Interferometry.CLI do
  @moduledoc """
  Wrapper for the dftfringe-cli binary.
  Provides functions to generate DFT previews and run full interferogram analysis.

  Supports three modes configured via application config:
  - :native - calls dftfringe-cli directly (must be in PATH)
  - :docker - calls via docker run with volume mounts
  - :mock - returns dummy data for testing

  Additionally, when `use_sidecar: true` is configured, uses persistent sidecar
  processes instead of spawning a new CLI process per request. The sidecar mode
  uses the underlying :native or :docker mode to determine how to spawn the process.

  For DFT preview generation, alternative implementations are available:
  - `dft_backend: :sidecar` (default) - uses the C++ sidecar/CLI
  - `dft_backend: :nx` - uses pure Elixir/Nx/Evision implementation (synchronous)
  - `dft_backend: :pool` - uses a pool of Nx workers (async, latest-wins for high framerate)
  """

  require Logger

  alias RougailSolstice.Interferometry.DFT.Nx, as: DFTNx
  alias RougailSolstice.Interferometry.DFT.Pool, as: DFTPool
  alias RougailSolstice.Interferometry.Sidecar.{Supervisor, Worker}

  @type circle :: %{cx: number(), cy: number(), r: number()}
  @type optical_params :: %{
          diameter: number(),
          roc: number(),
          lambda: number(),
          conic: number(),
          obstruction: number() | nil
        }
  @type dft_result :: {:file, Path.t()} | {:binary, binary()}
  @type wft_result :: {:file, Path.t()} | {:binary, binary()} | nil
  @type analysis_result :: %{
          rms_waves: float(),
          pv_waves: float(),
          strehl: float(),
          zernikes_raw: %{integer() => float()},
          zernikes_nulled: %{integer() => float()},
          wft: wft_result(),
          csv_path: Path.t() | nil
        }

  @doc """
  Returns whether sidecar mode is enabled.
  """
  @spec use_sidecar?() :: boolean()
  def use_sidecar?, do: Keyword.get(config(), :use_sidecar, false)

  @doc """
  Returns the DFT backend to use for preview generation.
  - `:sidecar` (default) - uses C++ sidecar/CLI
  - `:nx` - uses Elixir/Nx/Evision implementation (synchronous)
  - `:pool` - uses pool of Nx workers (async, latest-wins)
  """
  @spec dft_backend() :: :sidecar | :nx | :pool
  def dft_backend, do: Keyword.get(config(), :dft_backend, :sidecar)

  @doc """
  Returns the DFT size for Nx/pool backend (default: 512).
  """
  @spec dft_size() :: pos_integer()
  def dft_size, do: Keyword.get(config(), :dft_size, 512)

  @doc """
  Returns the pool size for pool backend (default: 10).
  """
  @spec dft_pool_size() :: pos_integer()
  def dft_pool_size, do: Keyword.get(config(), :dft_pool_size, 10)

  @doc """
  Generate a DFT preview image (synchronous).

  In file-based modes (native/docker), takes file paths, returns `{:ok, {:file, path}}`.
  In sidecar/nx/pool mode, takes binary data, returns `{:ok, {:binary, png_data}}`.

  Note: For high-framerate async processing, use `dft_preview_async/3` with `:pool` backend.
  """
  @spec dft_preview(Path.t() | binary(), circle(), Path.t() | nil | keyword()) ::
          {:ok, dft_result()} | {:error, term()}
  def dft_preview(input, circle, output_path_or_opts \\ nil)

  def dft_preview(input, circle, opts) when is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    output_path = Keyword.get(opts, :output_path)

    cond do
      mode() == :mock -> mock_dft_preview(output_path)
      dft_backend() == :pool -> run_dft_preview_pool_sync(input, circle, output_path)
      dft_backend() == :nx -> run_dft_preview_nx(input, circle, output_path)
      use_sidecar?() -> run_dft_preview_sidecar(input, circle, session_id)
      true -> run_dft_preview(input, circle, output_path)
    end
  end

  def dft_preview(input, circle, output_path) do
    dft_preview(input, circle, output_path: output_path)
  end

  @doc """
  Submit a DFT preview for async processing (pool backend only).

  Results are delivered via the pool's callback function.
  Returns `:ok` immediately.
  """
  @spec dft_preview_async(binary(), circle()) :: :ok | {:error, :pool_not_configured}
  def dft_preview_async(image_binary, circle) do
    if dft_backend() == :pool do
      DFTPool.submit(DFTPool, image_binary, circle)
    else
      {:error, :pool_not_configured}
    end
  end

  defp run_dft_preview_pool_sync(input, circle, output_path, timeout \\ 5000) do
    image_binary = ensure_binary(input)
    caller = self()
    ref = make_ref()

    callback = fn result ->
      send(caller, {ref, result})
    end

    {:ok, temp_pool} =
      DFTPool.start_link(
        pool_size: 1,
        dft_size: dft_size(),
        callback: callback
      )

    DFTPool.submit(temp_pool, image_binary, circle)

    result =
      receive do
        {^ref, {:ok, png_binary, _metadata}} ->
          if output_path do
            File.write!(output_path, png_binary)
            {:ok, {:file, output_path}}
          else
            {:ok, {:binary, png_binary}}
          end

        {^ref, {:error, reason}} ->
          {:error, reason}
      after
        timeout ->
          {:error, :timeout}
      end

    GenServer.stop(temp_pool)
    result
  end

  defp run_dft_preview_nx(input, circle, output_path) do
    image_binary = ensure_binary(input)

    case DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: dft_size()) do
      {:ok, png_binary} ->
        if output_path do
          File.write!(output_path, png_binary)
          {:ok, {:file, output_path}}
        else
          {:ok, {:binary, png_binary}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mock_dft_preview(output_path) do
    data = "mock dft preview"

    if output_path do
      File.write!(output_path, data)
      {:ok, {:file, output_path}}
    else
      {:ok, {:binary, data}}
    end
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
      "--input",
      input_path,
      "--circle",
      format_circle(circle),
      "--dft-preview",
      "--dft-output",
      output_path
    ]

    case System.cmd("dftfringe-cli", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path),
          do: {:ok, {:file, output_path}},
          else: {:error, :output_not_created}

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
        "--input",
        container_input,
        "--circle",
        format_circle(circle),
        "--dft-preview",
        "--dft-output",
        container_output
      ]

      docker_args =
        ["run", "--rm", "-v", "#{staging_dir}:#{docker_mount_dir()}", docker_image()] ++ args

      Logger.debug("[CLI] Running: docker #{Enum.join(docker_args, " ")}")

      case System.cmd("docker", docker_args, stderr_to_stdout: true) do
        {_output, 0} ->
          staged_output = Path.join(staging_dir, output_basename)

          if File.exists?(staged_output) do
            File.cp!(staged_output, output_path)
            {:ok, {:file, output_path}}
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

    cond do
      mode() == :mock ->
        {:ok, output} = {:ok, mock_output()}
        {:ok, parsed} = parse_structured_output(output)
        {:ok, Map.merge(parsed, %{wft: nil, csv_path: nil})}

      use_sidecar?() ->
        run_analyze_sidecar(input_path, circle, params, center_filter, wft_path, csv_path)

      mode() == :native ->
        run_analyze_native(input_path, circle, params, center_filter, wft_path, csv_path)

      mode() == :docker ->
        run_analyze_docker(input_path, circle, params, center_filter, wft_path, csv_path)
    end
  end

  defp run_analyze_native(input_path, circle, params, center_filter, wft_path, csv_path) do
    args = build_analyze_args(input_path, circle, params, center_filter, wft_path, csv_path)

    case System.cmd("dftfringe-cli", args, stderr_to_stdout: true) do
      {output, 0} ->
        with {:ok, parsed} <- parse_structured_output(output) do
          wft_result = if File.exists?(wft_path), do: {:file, wft_path}

          result =
            parsed
            |> Map.put(:wft, wft_result)
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

      args =
        build_analyze_args(
          container_input,
          circle,
          params,
          center_filter,
          container_wft,
          container_csv
        )

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
            wft_result = if File.exists?(wft_path), do: {:file, wft_path}

            result =
              parsed
              |> Map.put(:wft, wft_result)
              |> Map.put(:csv_path, if(File.exists?(csv_path), do: csv_path))

            Logger.info(
              "[CLI] Parsed result: rms=#{result.rms_waves}, pv=#{result.pv_waves}, strehl=#{result.strehl}"
            )

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
    png_path = String.replace_suffix(wft_path, ".wft", "_wavefront.png")

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
      "--zernike-terms",
      "48",
      "--structured-output",
      "--output",
      wft_path,
      "--zernikes",
      csv_path,
      "--wavefront-png",
      png_path
    ]

    if params[:obstruction] && params.obstruction > 0 do
      base ++ ["--obstruction", to_string(params.obstruction)]
    else
      base
    end
  end

  defp run_dft_preview_sidecar(input, circle, session_id) do
    image_binary = ensure_binary(input)
    worker = Supervisor.preview_worker(session_id)

    with {:ok, response} <- Worker.send_preview(worker, image_binary, circle),
         {:ok, png_binary} <- decode_base64_field(response, :dft) do
      {:ok, {:binary, png_binary}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_binary(data) when is_binary(data) do
    if File.exists?(data) do
      File.read!(data)
    else
      data
    end
  end

  defp run_analyze_sidecar(input, circle, params, center_filter, _wft_path, _csv_path) do
    config = %{
      diameter: params.diameter,
      roc: params.roc,
      lambda: params.lambda,
      conic: params.conic,
      obstruction: params[:obstruction] || 0,
      center_filter: center_filter,
      do_null: true,
      auto_invert: true,
      zernike_terms: 48
    }

    worker = Supervisor.analyze_worker()
    image_binary = ensure_binary(input)

    with {:ok, _} <- Worker.send_config(worker, config),
         {:ok, response} <- Worker.send_analyze(worker, image_binary, circle) do
      wft_result =
        case response[:wft] do
          nil ->
            nil

          wft_b64 ->
            case Base.decode64(wft_b64) do
              {:ok, wft_binary} -> {:binary, wft_binary}
              :error -> nil
            end
        end

      result = %{
        rms_waves: response[:rms] || 0.0,
        pv_waves: response[:pv] || 0.0,
        strehl: response[:strehl] || 0.0,
        zernikes_raw: extract_zernikes(response),
        zernikes_nulled: extract_zernikes(response),
        wft: wft_result,
        csv_path: nil
      }

      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_zernikes(response) do
    response
    |> Enum.filter(fn {key, _} ->
      key_str = to_string(key)
      String.starts_with?(key_str, "z") and String.length(key_str) <= 3
    end)
    |> Enum.map(fn {key, value} ->
      index = key |> to_string() |> String.slice(1..-1//1) |> String.to_integer()
      {index, value}
    end)
    |> Map.new()
  end

  defp decode_base64_field(response, key) do
    case response[key] do
      nil -> {:error, {:missing_field, key}}
      value -> Base.decode64(value)
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
