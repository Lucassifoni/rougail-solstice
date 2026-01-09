defmodule RougailSolstice.Interferometry.WFT do
  @moduledoc """
  Parser and renderer for DFTFringe WFT (WaveFronT) files.

  WFT file format:
  - Line 1: width (integer)
  - Line 2: height (integer)
  - Next width*height lines: one double value per line, stored row-by-row from bottom to top
  - Metadata lines: "outside ellipse cx cy rx ry", "DIAM mm", "ROC mm", "Lambda nm"

  Data storage convention:
  - File stores rows bottom-to-top (row 0 in file = bottom row of image)
  - We load into memory top-to-bottom (row 0 in memory = top row of image)
  - This matches DFTFringe's `data.at<double>(height - y - 1, x)` pattern
  """

  require Logger

  @type wavefront :: %{
          width: pos_integer(),
          height: pos_integer(),
          data: list(list(float())),
          mask: list(list(0 | 255)),
          outside: %{cx: float(), cy: float(), rx: float(), ry: float()} | nil,
          obstruction: %{cx: float(), cy: float(), rx: float(), ry: float()} | nil,
          diameter: float() | nil,
          roc: float() | nil,
          lambda: float() | nil,
          min: float(),
          max: float(),
          mean: float(),
          std: float()
        }

  @output_lambda 550.0
  @num_zernike_terms 9

  @spec parse_file(Path.t(), keyword()) :: {:ok, wavefront()} | {:error, term()}
  def parse_file(path, opts \\ []) do
    case File.read(path) do
      {:ok, content} -> parse(content, opts)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec parse(String.t(), keyword()) :: {:ok, wavefront()} | {:error, term()}
  def parse(content, opts \\ []) do
    apply_null = Keyword.get(opts, :apply_null, true)
    lines = String.split(content, "\n", trim: true)

    with {:ok, width, height, rest} <- parse_dimensions(lines),
         {:ok, data, mask, metadata_lines} <- parse_data(rest, width, height),
         metadata <- parse_metadata(metadata_lines, width, height) do
      outside = metadata[:outside] || default_outside(width, height)

      final_data =
        if apply_null do
          apply_zernike_null(data, mask, outside)
        else
          data
        end

      {min, max, mean, std} = compute_statistics(final_data, mask)

      {:ok,
       %{
         width: width,
         height: height,
         data: final_data,
         mask: mask,
         outside: outside,
         obstruction: metadata[:obstruction],
         diameter: metadata[:diameter],
         roc: metadata[:roc],
         lambda: metadata[:lambda],
         min: min,
         max: max,
         mean: mean,
         std: std
       }}
    end
  rescue
    e -> {:error, {:parse_error, e, __STACKTRACE__}}
  end

  defp default_outside(width, height) do
    cx = (width - 1) / 2.0
    cy = (height - 1) / 2.0
    r = min(cx, cy) - 2
    %{cx: cx, cy: cy, rx: r, ry: r}
  end

  defp parse_dimensions([width_line, height_line | rest]) do
    with {width, _} <- Integer.parse(String.trim(width_line)),
         {height, _} <- Integer.parse(String.trim(height_line)) do
      {:ok, width, height, rest}
    else
      _ -> {:error, :invalid_dimensions}
    end
  end

  defp parse_dimensions(_), do: {:error, :missing_dimensions}

  defp parse_data(lines, width, height) do
    expected_count = width * height

    if length(lines) < expected_count do
      {:error, {:insufficient_data, length(lines), expected_count}}
    else
      {data_lines, metadata_lines} = Enum.split(lines, expected_count)

      values =
        Enum.map(data_lines, fn line ->
          case Float.parse(String.trim(line)) do
            {val, _} -> val
            :error -> 0.0
          end
        end)

      {data, mask} = build_matrices(values, width)
      {:ok, data, mask, metadata_lines}
    end
  end

  defp build_matrices(values, width) do
    rows =
      values
      |> Enum.chunk_every(width)
      |> Enum.reverse()

    mask =
      Enum.map(rows, fn row ->
        Enum.map(row, fn val ->
          if val == 0.0, do: 0, else: 255
        end)
      end)

    {rows, mask}
  end

  defp parse_metadata(lines, width, height) do
    default_cx = (width - 1) / 2.0
    default_cy = (height - 1) / 2.0
    default_r = min(default_cx, default_cy) - 2

    Enum.reduce(lines, %{}, fn line, acc ->
      line = String.trim(line)

      cond do
        String.starts_with?(line, "outside") ->
          case parse_ellipse_line(line) do
            {:ok, ellipse} -> Map.put(acc, :outside, ellipse)
            _ -> Map.put(acc, :outside, %{cx: default_cx, cy: default_cy, rx: default_r, ry: default_r})
          end

        String.starts_with?(line, "obstruction") ->
          case parse_ellipse_line(line) do
            {:ok, ellipse} -> Map.put(acc, :obstruction, ellipse)
            _ -> acc
          end

        String.starts_with?(line, "DIAM ") ->
          case parse_float_after(line, "DIAM ") do
            {:ok, val} -> Map.put(acc, :diameter, val)
            _ -> acc
          end

        String.starts_with?(line, "ROC ") ->
          case parse_float_after(line, "ROC ") do
            {:ok, val} -> Map.put(acc, :roc, val)
            _ -> acc
          end

        String.starts_with?(line, "Lambda ") ->
          case parse_float_after(line, "Lambda ") do
            {:ok, val} -> Map.put(acc, :lambda, val)
            _ -> acc
          end

        true ->
          acc
      end
    end)
  end

  defp parse_ellipse_line(line) do
    parts = String.split(line)

    case parts do
      [_, "ellipse", cx, cy, rx, ry] ->
        {:ok,
         %{
           cx: parse_float!(cx),
           cy: parse_float!(cy),
           rx: parse_float!(rx),
           ry: parse_float!(ry)
         }}

      [_, cx, cy, r] ->
        {:ok,
         %{
           cx: parse_float!(cx),
           cy: parse_float!(cy),
           rx: parse_float!(r),
           ry: parse_float!(r)
         }}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_float_after(line, prefix) do
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

  defp apply_zernike_null(data, mask, outside) do
    coefficients = fit_zernikes(data, mask, outside, @num_zernike_terms)
    enables = default_null_enables()
    subtract_zernikes(data, mask, outside, coefficients, enables)
  end

  defp default_null_enables do
    %{
      0 => true,
      1 => true,
      2 => true,
      3 => true,
      4 => false,
      5 => false,
      6 => true,
      7 => true,
      8 => false
    }
  end

  defp fit_zernikes(data, mask, outside, num_terms) do
    height = length(data)
    width = length(hd(data))

    cx = outside.cx
    cy = outside.cy
    radius = outside.rx

    step = max(1, div(width, 100))

    samples =
      for y <- 0..(height - 1)//step,
          x <- 0..(width - 1)//step,
          mask_val = get_at(mask, y, x),
          mask_val == 255,
          val = get_at(data, y, x),
          val != 0.0,
          ux = (x - cx) / radius,
          uy = (y - cy) / radius,
          rho = :math.sqrt(ux * ux + uy * uy),
          rho <= 1.0 do
        theta = :math.atan2(uy, ux)
        zerns = zernike_terms(rho, theta, num_terms)
        {zerns, val}
      end

    if length(samples) < num_terms do
      List.duplicate(0.0, num_terms)
    else
      solve_least_squares(samples, num_terms)
    end
  end

  defp solve_least_squares(samples, num_terms) do
    ata = for i <- 0..(num_terms - 1) do
      for j <- 0..(num_terms - 1) do
        Enum.reduce(samples, 0.0, fn {zerns, _val}, acc ->
          acc + Enum.at(zerns, i) * Enum.at(zerns, j)
        end)
      end
    end

    atb = for i <- 0..(num_terms - 1) do
      Enum.reduce(samples, 0.0, fn {zerns, val}, acc ->
        acc + Enum.at(zerns, i) * val
      end)
    end

    solve_linear_system(ata, atb)
  end

  defp solve_linear_system(a, b) do
    n = length(b)

    aug = Enum.zip(a, b) |> Enum.map(fn {row, bi} -> row ++ [bi] end)

    reduced = gaussian_elimination(aug, n)
    back_substitute(reduced, n)
  end

  defp gaussian_elimination(aug, n) do
    Enum.reduce(0..(n - 1), aug, fn k, aug_acc ->
      pivot_row = k
      pivot_val = abs(get_aug(aug_acc, k, k))

      {pivot_row, _pivot_val} =
        Enum.reduce((k + 1)..(n - 1)//1, {pivot_row, pivot_val}, fn i, {pr, pv} ->
          v = abs(get_aug(aug_acc, i, k))
          if v > pv, do: {i, v}, else: {pr, pv}
        end)

      aug_acc = swap_rows(aug_acc, k, pivot_row)

      pivot = get_aug(aug_acc, k, k)

      if abs(pivot) < 1.0e-12 do
        aug_acc
      else
        Enum.reduce((k + 1)..(n - 1)//1, aug_acc, fn i, acc ->
          factor = get_aug(acc, i, k) / pivot

          new_row =
            Enum.with_index(Enum.at(acc, i))
            |> Enum.map(fn {val, j} ->
              if j >= k do
                val - factor * get_aug(acc, k, j)
              else
                val
              end
            end)

          List.replace_at(acc, i, new_row)
        end)
      end
    end)
  end

  defp back_substitute(aug, n) do
    x = List.duplicate(0.0, n)

    Enum.reduce((n - 1)..0//-1, x, fn i, x_acc ->
      row = Enum.at(aug, i)
      diag = Enum.at(row, i)

      if abs(diag) < 1.0e-12 do
        x_acc
      else
        sum =
          Enum.reduce((i + 1)..(n - 1)//1, 0.0, fn j, acc ->
            acc + Enum.at(row, j) * Enum.at(x_acc, j)
          end)

        val = (Enum.at(row, n) - sum) / diag
        List.replace_at(x_acc, i, val)
      end
    end)
  end

  defp get_aug(aug, row, col), do: Enum.at(Enum.at(aug, row), col)

  defp swap_rows(aug, i, j) when i == j, do: aug
  defp swap_rows(aug, i, j) do
    row_i = Enum.at(aug, i)
    row_j = Enum.at(aug, j)
    aug |> List.replace_at(i, row_j) |> List.replace_at(j, row_i)
  end

  defp subtract_zernikes(data, mask, outside, coefficients, enables) do
    cx = outside.cx
    cy = outside.cy
    radius = outside.rx

    for {row, y} <- Enum.with_index(data) do
      mask_row = Enum.at(mask, y)

      for {val, x} <- Enum.with_index(row) do
        m = Enum.at(mask_row, x)

        if m != 255 or val == 0.0 do
          val
        else
          ux = (x - cx) / radius
          uy = (y - cy) / radius
          rho = :math.sqrt(ux * ux + uy * uy)

          if rho > 1.0 do
            val
          else
            theta = :math.atan2(uy, ux)
            zerns = zernike_terms(rho, theta, length(coefficients))

            zern_contribution =
              coefficients
              |> Enum.with_index()
              |> Enum.reduce(0.0, fn {coef, i}, acc ->
                if Map.get(enables, i, false) do
                  acc + coef * Enum.at(zerns, i)
                else
                  acc
                end
              end)

            val - zern_contribution
          end
        end
      end
    end
  end

  defp zernike_terms(rho, theta, num_terms) when num_terms >= 9 do
    rho2 = rho * rho
    cos_theta = :math.cos(theta)
    sin_theta = :math.sin(theta)
    cos_2theta = :math.cos(2.0 * theta)
    sin_2theta = :math.sin(2.0 * theta)

    [
      1.0,
      rho * cos_theta,
      rho * sin_theta,
      -1.0 + 2.0 * rho2,
      rho2 * cos_2theta,
      rho2 * sin_2theta,
      rho * (-2.0 + 3.0 * rho2) * cos_theta,
      rho * (-2.0 + 3.0 * rho2) * sin_theta,
      1.0 + rho2 * (-6.0 + 6.0 * rho2)
    ]
  end

  defp get_at(matrix, row, col) do
    Enum.at(Enum.at(matrix, row), col)
  end

  defp compute_statistics(data, mask) do
    valid_values =
      data
      |> Enum.zip(mask)
      |> Enum.flat_map(fn {data_row, mask_row} ->
        Enum.zip(data_row, mask_row)
        |> Enum.filter(fn {_val, m} -> m == 255 end)
        |> Enum.map(fn {val, _m} -> val end)
      end)

    if Enum.empty?(valid_values) do
      {0.0, 0.0, 0.0, 0.01}
    else
      min_val = Enum.min(valid_values)
      max_val = Enum.max(valid_values)
      n = length(valid_values)
      mean = Enum.sum(valid_values) / n

      variance =
        valid_values
        |> Enum.map(fn v -> (v - mean) * (v - mean) end)
        |> Enum.sum()
        |> Kernel./(n)

      std = max(:math.sqrt(variance), 0.01)

      {min_val, max_val, mean, std}
    end
  end

  @spec render_to_png(wavefront(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def render_to_png(wft, _opts \\ []) do
    lambda = wft.lambda || @output_lambda
    lambda_scale = lambda / @output_lambda

    {z_min, z_max} = compute_z_range(wft.mean, wft.std)
    z_range = max(z_max - z_min, 1.0e-10)

    height = wft.height
    width = wft.width

    rgb_rows =
      wft.data
      |> Enum.zip(wft.mask)
      |> Enum.map(fn {data_row, mask_row} ->
        Enum.zip(data_row, mask_row)
        |> Enum.map(fn {val, m} ->
          if m != 255 do
            <<0, 0, 0>>
          else
            scaled_val = val * lambda_scale
            t = clamp((scaled_val - z_min) / z_range, 0.0, 1.0)
            hotcold_to_bgr(t)
          end
        end)
        |> IO.iodata_to_binary()
      end)

    rgb_binary = IO.iodata_to_binary(rgb_rows)
    mat = Evision.Mat.from_binary(rgb_binary, :u8, height, width, 3)

    case Evision.imencode(".png", mat) do
      {:ok, binary} -> {:ok, binary, %{min: z_min, max: z_max, mean: wft.mean, std: wft.std, width: width, height: height}}
      binary when is_binary(binary) -> {:ok, binary, %{min: z_min, max: z_max, mean: wft.mean, std: wft.std, width: width, height: height}}
      error -> {:error, {:encode_failed, error}}
    end
  rescue
    e ->
      Logger.error("[WFT] Render failed: #{inspect(e)}")
      {:error, {:render_error, e}}
  end

  defp compute_z_range(mean, std) do
    z_min = mean - 3 * std
    z_max = mean + 3 * std
    {z_min, z_max}
  end

  @hotcold_stops [
    {0.00, {0, 0, 0}},
    {0.15, {0, 0, 255}},
    {0.25, {0, 255, 255}},
    {0.50, {150, 60, 0}},
    {0.75, {160, 160, 160}},
    {0.90, {255, 0, 0}},
    {0.99, {255, 255, 0}}
  ]

  defp hotcold_to_bgr(t) do
    {r, g, b} = interpolate_colormap(t, @hotcold_stops)
    <<b, g, r>>
  end

  defp interpolate_colormap(t, stops) do
    t = clamp(t, 0.0, 1.0)

    case find_bounding_stops(t, stops) do
      {low_pos, low_color, high_pos, _high_color} when low_pos == high_pos ->
        low_color

      {low_pos, {lr, lg, lb}, high_pos, {hr, hg, hb}} ->
        ratio = (t - low_pos) / (high_pos - low_pos)

        {
          round(lr + (hr - lr) * ratio),
          round(lg + (hg - lg) * ratio),
          round(lb + (hb - lb) * ratio)
        }
    end
  end

  defp find_bounding_stops(t, stops) do
    sorted = Enum.sort_by(stops, fn {pos, _} -> pos end)

    case Enum.find_index(sorted, fn {pos, _} -> pos >= t end) do
      nil ->
        {pos, color} = List.last(sorted)
        {pos, color, pos, color}

      0 ->
        {pos, color} = hd(sorted)
        {pos, color, pos, color}

      idx ->
        {low_pos, low_color} = Enum.at(sorted, idx - 1)
        {high_pos, high_color} = Enum.at(sorted, idx)
        {low_pos, low_color, high_pos, high_color}
    end
  end

  defp clamp(val, min_v, max_v), do: max(min_v, min(max_v, val))
end
