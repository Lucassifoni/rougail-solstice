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

  @spec render_to_png(wavefront(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render_to_png(wft, opts \\ []) do
    output_size = Keyword.get(opts, :size, 512)
    background_color = Keyword.get(opts, :background, {40, 40, 40})

    {height, width} = Nx.shape(wft.data)
    data = wft.data

    mask = create_circular_mask(width, height, wft.outside_circle, wft.inside_circle)

    valid_values =
      data
      |> Nx.to_flat_list()
      |> Enum.zip(Nx.to_flat_list(mask))
      |> Enum.filter(fn {_val, m} -> m == 1 end)
      |> Enum.map(fn {val, _} -> val end)
      |> Enum.reject(&is_nan/1)

    if Enum.empty?(valid_values) do
      {:error, :no_valid_data}
    else
      min_val = Enum.min(valid_values)
      max_val = Enum.max(valid_values)
      range = max(max_val - min_val, 1.0e-10)

      normalized =
        data
        |> Nx.subtract(min_val)
        |> Nx.divide(range)
        |> Nx.clip(0.0, 1.0)

      {r, g, b} = apply_colormap(normalized)

      rgb_image =
        Nx.stack([b, g, r], axis: -1)
        |> Nx.as_type(:u8)
        |> Nx.backend_transfer(Nx.BinaryBackend)

      mask = Nx.backend_transfer(mask, Nx.BinaryBackend)
      rgb_image = apply_mask_background(rgb_image, mask, background_color)

      mat = nx_to_bgr_mat(rgb_image)

      resized =
        if width != output_size or height != output_size do
          case Evision.resize(mat, {output_size, output_size}) do
            %Evision.Mat{} = result -> result
            {:error, _} = err -> raise "Resize failed: #{inspect(err)}"
          end
        else
          mat
        end

      with_scale = add_color_scale(resized, min_val, max_val)

      case Evision.imencode(".png", with_scale) do
        {:ok, binary} -> {:ok, binary}
        binary when is_binary(binary) -> {:ok, binary}
        error -> {:error, {:encode_failed, error}}
      end
    end
  rescue
    e ->
      Logger.error("[WFT] Render failed: #{inspect(e)}")
      {:error, {:render_error, e}}
  end

  defp is_nan(x) when is_float(x), do: x != x
  defp is_nan(_), do: false

  defp nx_to_bgr_mat(rgb_tensor) do
    {height, width, 3} = Nx.shape(rgb_tensor)

    rgb_binary = Nx.backend_transfer(rgb_tensor, Nx.BinaryBackend)

    b = rgb_binary |> Nx.slice([0, 0, 0], [height, width, 1]) |> Nx.squeeze(axes: [2])
    g = rgb_binary |> Nx.slice([0, 0, 1], [height, width, 1]) |> Nx.squeeze(axes: [2])
    r = rgb_binary |> Nx.slice([0, 0, 2], [height, width, 1]) |> Nx.squeeze(axes: [2])

    b_mat = Evision.Mat.from_nx(b)
    g_mat = Evision.Mat.from_nx(g)
    r_mat = Evision.Mat.from_nx(r)

    Evision.merge([b_mat, g_mat, r_mat])
  end

  defp create_circular_mask(width, height, outside_circle, inside_circle) do
    y_coords = Nx.iota({height, width}, axis: 0) |> Nx.as_type(:f64)
    x_coords = Nx.iota({height, width}, axis: 1) |> Nx.as_type(:f64)

    mask =
      if outside_circle do
        cx = outside_circle.cx
        cy = outside_circle.cy
        r = outside_circle.r

        dx = Nx.subtract(x_coords, cx)
        dy = Nx.subtract(y_coords, cy)
        dist_sq = Nx.add(Nx.pow(dx, 2), Nx.pow(dy, 2))

        Nx.less_equal(dist_sq, r * r)
      else
        Nx.broadcast(1, {height, width}) |> Nx.as_type(:u8)
      end

    mask =
      if inside_circle && inside_circle.r > 0 do
        cx = inside_circle.cx
        cy = inside_circle.cy
        r = inside_circle.r

        dx = Nx.subtract(x_coords, cx)
        dy = Nx.subtract(y_coords, cy)
        dist_sq = Nx.add(Nx.pow(dx, 2), Nx.pow(dy, 2))

        inside_mask = Nx.greater(dist_sq, r * r)
        Nx.logical_and(mask, inside_mask)
      else
        mask
      end

    mask
  end

  defp apply_colormap(normalized) do
    t = normalized

    r =
      t
      |> Nx.multiply(2.0)
      |> Nx.subtract(1.0)
      |> Nx.clip(0.0, 1.0)
      |> Nx.multiply(255.0)

    b =
      Nx.subtract(1.0, t)
      |> Nx.multiply(2.0)
      |> Nx.clip(0.0, 1.0)
      |> Nx.multiply(255.0)

    g =
      Nx.subtract(0.5, Nx.abs(Nx.subtract(t, 0.5)))
      |> Nx.multiply(4.0)
      |> Nx.clip(0.0, 1.0)
      |> Nx.multiply(255.0)

    {r, g, b}
  end

  defp apply_mask_background(rgb_image, mask, {bg_r, bg_g, bg_b}) do
    mask_3d = Nx.stack([mask, mask, mask], axis: -1)

    background =
      Nx.tensor([bg_b, bg_g, bg_r], type: :u8)
      |> Nx.broadcast(Nx.shape(rgb_image))

    Nx.select(mask_3d, rgb_image, background)
  end

  defp add_color_scale(mat, min_val, max_val) do
    {height, width, _} = Evision.Mat.shape(mat)

    scale_width = 60
    padding = 10
    new_width = width + scale_width + padding

    canvas = Evision.Mat.zeros({height, new_width, 3}, :u8)

    canvas = Evision.rectangle(canvas, {0, 0}, {new_width - 1, height - 1}, {40, 40, 40}, thickness: -1)

    roi = {0, 0, width, height}
    canvas = copy_roi(canvas, mat, roi)

    scale_x = width + padding
    scale_height = height - 40
    scale_y_start = 20

    canvas = draw_gradient_bar(canvas, scale_x, scale_y_start, 20, scale_height)

    canvas =
      Evision.putText(
        canvas,
        format_value(max_val),
        {scale_x + 25, scale_y_start + 12},
        Evision.Constant.cv_FONT_HERSHEY_SIMPLEX(),
        0.35,
        {255, 255, 255},
        thickness: 1
      )

    canvas =
      Evision.putText(
        canvas,
        format_value(min_val),
        {scale_x + 25, scale_y_start + scale_height},
        Evision.Constant.cv_FONT_HERSHEY_SIMPLEX(),
        0.35,
        {255, 255, 255},
        thickness: 1
      )

    mid_val = (max_val + min_val) / 2

    canvas =
      Evision.putText(
        canvas,
        format_value(mid_val),
        {scale_x + 25, scale_y_start + div(scale_height, 2) + 4},
        Evision.Constant.cv_FONT_HERSHEY_SIMPLEX(),
        0.35,
        {255, 255, 255},
        thickness: 1
      )

    Evision.putText(
      canvas,
      "waves",
      {scale_x, height - 8},
      Evision.Constant.cv_FONT_HERSHEY_SIMPLEX(),
      0.35,
      {200, 200, 200},
      thickness: 1
    )
  end

  defp copy_roi(canvas, src, {x, y, w, h}) do
    src_tensor = Evision.Mat.to_nx(src, Nx.BinaryBackend)
    canvas_tensor = Evision.Mat.to_nx(canvas, Nx.BinaryBackend)

    {src_h, src_w, _} = Nx.shape(src_tensor)
    copy_h = min(src_h, h)
    copy_w = min(src_w, w)

    src_slice = Nx.slice(src_tensor, [0, 0, 0], [copy_h, copy_w, 3])

    canvas_tensor = Nx.put_slice(canvas_tensor, [y, x, 0], src_slice)
    nx_to_bgr_mat(canvas_tensor)
  end

  defp draw_gradient_bar(canvas, x, y, bar_width, bar_height) do
    canvas_tensor = Evision.Mat.to_nx(canvas, Nx.BinaryBackend)

    gradient =
      for row <- 0..(bar_height - 1) do
        t = 1.0 - row / max(bar_height - 1, 1)
        {r, g, b} = value_to_color(t)

        for _ <- 0..(bar_width - 1) do
          [b, g, r]
        end
      end

    gradient_tensor = Nx.tensor(gradient, type: :u8)

    canvas_tensor = Nx.put_slice(canvas_tensor, [y, x, 0], gradient_tensor)
    nx_to_bgr_mat(canvas_tensor)
  end

  defp value_to_color(t) do
    r = round(min(1.0, max(0.0, (t - 0.5) * 2)) * 255)
    b = round(min(1.0, max(0.0, (1 - t) * 2)) * 255)
    g = round(min(1.0, max(0.0, 1 - abs(t - 0.5) * 4)) * 255)
    {r, g, b}
  end

  defp format_value(val) when abs(val) < 0.01, do: :erlang.float_to_binary(val, decimals: 4)
  defp format_value(val) when abs(val) < 1, do: :erlang.float_to_binary(val, decimals: 3)
  defp format_value(val), do: :erlang.float_to_binary(val, decimals: 2)
end
