defmodule RougailSolstice.Interferometry.WFT do
  @moduledoc """
  Parser and renderer for DFTFringe WFT (WaveFronT) files.

  WFT file format:
  - Line 1: "<width> <height>"
  - Next width*height lines: one double value per line (row-by-row, bottom-to-top)
  - Metadata lines: "outside ellipse <cx> <cy> <rx> <ry>", "DIAM <mm>", etc.
  """

  require Logger

  @type wavefront :: %{
          width: pos_integer(),
          height: pos_integer(),
          data: Nx.Tensor.t(),
          outside_circle: %{cx: float(), cy: float(), r: float()} | nil,
          inside_circle: %{cx: float(), cy: float(), r: float()} | nil,
          diameter: float() | nil,
          roc: float() | nil,
          lambda: float() | nil
        }

  @spec parse_file(Path.t()) :: {:ok, wavefront()} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec parse(String.t()) :: {:ok, wavefront()} | {:error, term()}
  def parse(content) do
    lines = String.split(content, "\n", trim: true)

    with [width_line, height_line | rest] <- lines,
         {:ok, width} <- parse_int_line(width_line),
         {:ok, height} <- parse_int_line(height_line),
         {data_lines, metadata_lines} <- Enum.split(rest, width * height),
         {:ok, data} <- parse_data(data_lines, width, height),
         metadata <- parse_metadata(metadata_lines) do
      {:ok,
       %{
         width: width,
         height: height,
         data: data,
         outside_circle: metadata[:outside_circle],
         inside_circle: metadata[:inside_circle],
         diameter: metadata[:diameter],
         roc: metadata[:roc],
         lambda: metadata[:lambda]
       }}
    else
      [] -> {:error, :empty_file}
      [_] -> {:error, :missing_height}
      {:error, _} = error -> error
    end
  rescue
    e -> {:error, {:parse_error, e}}
  end

  defp parse_int_line(line) do
    case Integer.parse(String.trim(line)) do
      {val, _} -> {:ok, val}
      :error -> {:error, :invalid_integer}
    end
  end

  defp parse_data(lines, width, height) do
    expected_count = width * height

    if length(lines) < expected_count do
      {:error, {:insufficient_data, length(lines), expected_count}}
    else
      values =
        lines
        |> Enum.take(expected_count)
        |> Enum.map(fn line ->
          case Float.parse(String.trim(line)) do
            {val, _} -> val
            :error -> 0.0
          end
        end)

      tensor =
        values
        |> Nx.tensor(type: :f64)
        |> Nx.reshape({height, width})
        |> Nx.reverse(axes: [0])

      {:ok, tensor}
    end
  end

  defp parse_metadata(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      cond do
        String.starts_with?(line, "outside ellipse") ||
            String.starts_with?(line, "outside ") ->
          case parse_circle_line(line) do
            {:ok, circle} -> Map.put(acc, :outside_circle, circle)
            _ -> acc
          end

        String.starts_with?(line, "obstruction ellipse") ||
            String.starts_with?(line, "obstruction ") ->
          case parse_circle_line(line) do
            {:ok, circle} -> Map.put(acc, :inside_circle, circle)
            _ -> acc
          end

        String.starts_with?(line, "DIAM ") ->
          case parse_float_value(line, "DIAM ") do
            {:ok, val} -> Map.put(acc, :diameter, val)
            _ -> acc
          end

        String.starts_with?(line, "ROC ") ->
          case parse_float_value(line, "ROC ") do
            {:ok, val} -> Map.put(acc, :roc, val)
            _ -> acc
          end

        String.starts_with?(line, "Lambda ") ->
          case parse_float_value(line, "Lambda ") do
            {:ok, val} -> Map.put(acc, :lambda, val)
            _ -> acc
          end

        true ->
          acc
      end
    end)
  end

  defp parse_circle_line(line) do
    parts = String.split(line)

    case parts do
      [_, "ellipse", cx, cy, rx, _ry] ->
        {:ok,
         %{
           cx: parse_float!(cx),
           cy: parse_float!(cy),
           r: parse_float!(rx)
         }}

      [_, cx, cy, r] ->
        {:ok,
         %{
           cx: parse_float!(cx),
           cy: parse_float!(cy),
           r: parse_float!(r)
         }}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_float_value(line, prefix) do
    value_str = String.trim_leading(line, prefix) |> String.trim()

    case Float.parse(value_str) do
      {val, _} -> {:ok, val}
      :error -> :error
    end
  end

  defp parse_float!(str) do
    {val, _} = Float.parse(str)
    val
  end

  @spec render_to_png(wavefront(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def render_to_png(wft, opts \\ []) do
    output_size = Keyword.get(opts, :size, 512)

    {height, width} = Nx.shape(wft.data)
    flat_data = Nx.to_flat_list(wft.data)

    valid_values = Enum.reject(flat_data, &is_nan/1)

    if Enum.empty?(valid_values) do
      {:error, :no_valid_data}
    else
      min_val = Enum.min(valid_values)
      max_val = Enum.max(valid_values)
      range = max(max_val - min_val, 1.0e-10)

      rgb_binary =
        flat_data
        |> Enum.map(fn val ->
          t = clamp((val - min_val) / range, 0.0, 1.0)
          value_to_bgr(t)
        end)
        |> IO.iodata_to_binary()

      mat = Evision.Mat.from_binary(rgb_binary, :u8, height, width, 3)

      resized =
        if width != output_size or height != output_size do
          case Evision.resize(mat, {output_size, output_size}) do
            %Evision.Mat{} = result -> result
            {:error, _} = err -> raise "Resize failed: #{inspect(err)}"
          end
        else
          mat
        end

      case Evision.imencode(".png", resized) do
        {:ok, binary} -> {:ok, binary, %{min: min_val, max: max_val}}
        binary when is_binary(binary) -> {:ok, binary, %{min: min_val, max: max_val}}
        error -> {:error, {:encode_failed, error}}
      end
    end
  rescue
    e ->
      Logger.error("[WFT] Render failed: #{inspect(e)}")
      {:error, {:render_error, e}}
  end

  defp clamp(val, min_v, max_v), do: max(min_v, min(max_v, val))

  defp value_to_bgr(t) do
    r = round(clamp((t - 0.5) * 2, 0.0, 1.0) * 255)
    b = round(clamp((1 - t) * 2, 0.0, 1.0) * 255)
    g = round(clamp(1 - abs(t - 0.5) * 4, 0.0, 1.0) * 255)
    <<b, g, r>>
  end

  defp is_nan(x) when is_float(x), do: x != x
  defp is_nan(_), do: false
end
