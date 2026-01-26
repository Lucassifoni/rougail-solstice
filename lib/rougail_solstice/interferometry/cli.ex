defmodule RougailSolstice.Interferometry.CLI do
  @moduledoc """
  Interface for interferometry analysis.
  Provides functions to generate DFT previews and run full interferogram analysis.

  All operations use in-memory binary data - no filesystem I/O.

  DFT preview uses pure Elixir/Nx/Evision implementation.
  Analysis uses the sidecar process (C++ via dftfringe-cli).
  """

  require Logger

  alias RougailSolstice.Interferometry.DFT.Nx, as: DFTNx
  alias RougailSolstice.Interferometry.Sidecar.{Supervisor, Worker}

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
          wft: {:binary, binary()} | nil,
          csv_path: nil
        }

  @doc """
  Returns the DFT size (default: 512).
  """
  @spec dft_size() :: pos_integer()
  def dft_size, do: Keyword.get(config(), :dft_size, 512)

  @doc """
  Generate a DFT preview image from binary data using Nx/Evision.
  Returns `{:ok, {:binary, png_data}}` on success.
  """
  @spec dft_preview(binary(), circle(), keyword()) ::
          {:ok, {:binary, binary()}} | {:error, term()}
  def dft_preview(image_binary, circle, _opts \\ []) do
    case mode() do
      :mock -> {:ok, {:binary, mock_png_data()}}
      _ -> run_dft_preview_nx(image_binary, circle)
    end
  end

  defp run_dft_preview_nx(image_binary, circle) do
    case DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: dft_size()) do
      {:ok, png_binary} -> {:ok, {:binary, png_binary}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run full interferogram analysis on binary image data.
  Returns analysis results with WFT data as binary.
  """
  @spec analyze(binary(), circle(), optical_params(), keyword()) ::
          {:ok, analysis_result()} | {:error, term()}
  def analyze(image_binary, circle, params, opts \\ []) do
    case mode() do
      :mock -> {:ok, mock_analysis_result()}
      _ -> run_analyze_sidecar(image_binary, circle, params, opts)
    end
  end

  defp run_analyze_sidecar(image_binary, circle, params, opts) do
    session_id = Keyword.get(opts, :session_id)
    center_filter = Keyword.get(opts, :center_filter, 10)

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

    worker = Supervisor.analyze_worker(session_id)

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

  defp config do
    Application.get_env(:rougail_solstice, __MODULE__, [])
  end

  defp mode, do: Keyword.get(config(), :mode, :sidecar)

  defp mock_png_data do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "mock"::binary>>
  end

  defp mock_analysis_result do
    %{
      rms_waves: 0.05,
      pv_waves: 0.25,
      strehl: 0.95,
      zernikes_raw: %{1 => 0.001, 2 => 0.002},
      zernikes_nulled: %{1 => 0.0005, 2 => 0.001},
      wft: nil,
      csv_path: nil
    }
  end
end
