defmodule RougailSolstice.Interferometry.WFT.Nx do
  @moduledoc """
  Nx-accelerated implementation of WFT (WaveFronT) parsing and rendering.

  This module provides the same interface as `RougailSolstice.Interferometry.WFT`
  but uses Nx tensors for numerical operations, leveraging EXLA for acceleration.

  Key optimizations:
  - Vectorized Zernike fitting using Nx.LinAlg.solve
  - Fully tensorized per-pixel operations (no nested comprehensions)
  - Native Nx statistics (mean, variance, min, max)
  - Vectorized colormap interpolation
  """

  require Logger

  @type wavefront :: %{
          width: pos_integer(),
          height: pos_integer(),
          data: Nx.Tensor.t(),
          mask: Nx.Tensor.t(),
          outside: %{cx: float(), cy: float(), rx: float(), ry: float()} | nil,
          obstruction: %{cx: float(), cy: float(), rx: float(), ry: float()} | nil,
          diameter: float() | nil,
          roc: float() | nil,
          lambda: float() | nil,
          min: float(),
          max: float(),
          mean: float(),
          std: float(),
          ref_mean: float(),
          ref_std: float()
        }

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
    conic = Keyword.get(opts, :conic, -1.0)
    lines = String.split(content, "\n", trim: true)

    with {:ok, width, height, rest} <- parse_dimensions(lines),
         {:ok, data, mask, metadata_lines} <- parse_data(rest, width, height),
         metadata <- parse_metadata(metadata_lines, width, height) do
      outside = metadata[:outside] || default_outside(width, height)

      software_null =
        compute_software_null(metadata[:diameter], metadata[:roc], metadata[:lambda], conic)

      Logger.info(
        "[WFT.Nx] Software null: #{software_null} (D=#{metadata[:diameter]}, ROC=#{metadata[:roc]}, λ=#{metadata[:lambda]}, conic=#{conic})"
      )

      {final_data, ref_mean, ref_std} =
        if apply_null do
          {nulled_data, reference_surface} =
            apply_zernike_null(data, mask, outside, software_null)

          {_ref_min, _ref_max, ref_mean, ref_std} = compute_statistics(reference_surface, mask)
          {nulled_data, ref_mean, ref_std}
        else
          {_min, _max, mean, std} = compute_statistics(data, mask)
          {data, mean, std}
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
         std: std,
         ref_mean: ref_mean,
         ref_std: ref_std
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

      {data, mask} = build_tensors(values, width, height)
      {:ok, data, mask, metadata_lines}
    end
  end

  defp build_tensors(values, width, height) do
    data =
      values
      |> Nx.tensor(type: :f64)
      |> Nx.reshape({height, width})
      |> Nx.reverse(axes: [0])

    mask =
      data
      |> Nx.not_equal(0.0)
      |> Nx.select(255, 0)
      |> Nx.as_type(:u8)

    {data, mask}
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
            {:ok, ellipse} ->
              Map.put(acc, :outside, ellipse)

            _ ->
              Map.put(acc, :outside, %{
                cx: default_cx,
                cy: default_cy,
                rx: default_r,
                ry: default_r
              })
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

  defp compute_software_null(nil, _roc, _lambda, _conic), do: 0.0
  defp compute_software_null(_diameter, nil, _lambda, _conic), do: 0.0
  defp compute_software_null(_diameter, _roc, nil, _conic), do: 0.0
  defp compute_software_null(_diameter, _roc, _lambda, 0.0), do: 0.0

  defp compute_software_null(diameter, roc, lambda, conic) do
    z8_computed = :math.pow(diameter, 4) * 1_000_000.0 / (384.0 * :math.pow(roc, 3) * lambda)
    z8_computed * conic
  end

  defp apply_zernike_null(data, mask, outside, software_null) do
    coefficients = fit_zernikes(data, mask, outside, @num_zernike_terms)
    enables = default_null_enables()
    nulled_data = subtract_zernikes(data, mask, outside, coefficients, enables, software_null)

    reference_surface =
      reconstruct_reference_surface(mask, outside, coefficients, enables, software_null)

    {nulled_data, reference_surface}
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
    {height, width} = Nx.shape(data)

    cx = outside.cx
    cy = outside.cy
    radius = outside.rx

    step = max(1, div(width, 100))

    y_coords = Nx.iota({height, width}, axis: 0, type: :f64)
    x_coords = Nx.iota({height, width}, axis: 1, type: :f64)

    ux = Nx.divide(Nx.subtract(x_coords, cx), radius)
    uy = Nx.divide(Nx.subtract(y_coords, cy), radius)
    rho = Nx.sqrt(Nx.add(Nx.pow(ux, 2), Nx.pow(uy, 2)))
    theta = Nx.atan2(uy, ux)

    valid_mask =
      mask
      |> Nx.equal(255)
      |> Nx.logical_and(Nx.not_equal(data, 0.0))
      |> Nx.logical_and(Nx.less_equal(rho, 1.0))

    y_sample = Nx.iota({height}, type: :s32)
    x_sample = Nx.iota({width}, type: :s32)
    y_keep = Nx.remainder(y_sample, step) |> Nx.equal(0)
    x_keep = Nx.remainder(x_sample, step) |> Nx.equal(0)

    sample_mask =
      Nx.outer(y_keep, x_keep)
      |> Nx.as_type(:u8)
      |> Nx.logical_and(valid_mask)

    flat_sample_mask = Nx.flatten(sample_mask)
    num_valid = Nx.sum(flat_sample_mask) |> Nx.to_number() |> round()

    if num_valid < num_terms do
      List.duplicate(0.0, num_terms)
    else
      flat_rho = Nx.flatten(rho)
      flat_theta = Nx.flatten(theta)
      flat_data = Nx.flatten(data)

      sample_indices =
        flat_sample_mask
        |> Nx.as_type(:s32)
        |> Nx.argsort(direction: :desc)

      take_indices = Nx.slice(sample_indices, [0], [num_valid])

      sample_rho = Nx.take(flat_rho, take_indices)
      sample_theta = Nx.take(flat_theta, take_indices)
      sample_vals = Nx.take(flat_data, take_indices)

      design_matrix = build_zernike_design_matrix(sample_rho, sample_theta, num_terms)

      solve_least_squares_nx(design_matrix, sample_vals)
    end
  end

  defp build_zernike_design_matrix(rho, theta, _num_terms) do
    rho2 = Nx.pow(rho, 2)
    cos_theta = Nx.cos(theta)
    sin_theta = Nx.sin(theta)
    cos_2theta = Nx.cos(Nx.multiply(theta, 2.0))
    sin_2theta = Nx.sin(Nx.multiply(theta, 2.0))

    z0 = Nx.broadcast(1.0, Nx.shape(rho))
    z1 = Nx.multiply(rho, cos_theta)
    z2 = Nx.multiply(rho, sin_theta)
    z3 = Nx.add(Nx.multiply(rho2, 2.0), -1.0)
    z4 = Nx.multiply(rho2, cos_2theta)
    z5 = Nx.multiply(rho2, sin_2theta)
    z6 = Nx.multiply(Nx.multiply(rho, Nx.add(Nx.multiply(rho2, 3.0), -2.0)), cos_theta)
    z7 = Nx.multiply(Nx.multiply(rho, Nx.add(Nx.multiply(rho2, 3.0), -2.0)), sin_theta)
    z8 = Nx.add(1.0, Nx.multiply(rho2, Nx.add(Nx.multiply(rho2, 6.0), -6.0)))

    Nx.stack([z0, z1, z2, z3, z4, z5, z6, z7, z8], axis: 1)
  end

  defp solve_least_squares_nx(design_matrix, values) do
    a_t = Nx.transpose(design_matrix)
    ata = Nx.dot(a_t, design_matrix)
    atb = Nx.dot(a_t, values)

    regularization = Nx.multiply(Nx.eye(9, type: :f64), 1.0e-10)
    ata_reg = Nx.add(ata, regularization)

    solution = Nx.LinAlg.solve(ata_reg, atb)
    Nx.to_flat_list(solution)
  end

  defp subtract_zernikes(data, mask, outside, coefficients, enables, software_null) do
    {height, width} = Nx.shape(data)

    cx = outside.cx
    cy = outside.cy
    radius = outside.rx

    y_coords = Nx.iota({height, width}, axis: 0, type: :f64)
    x_coords = Nx.iota({height, width}, axis: 1, type: :f64)

    ux = Nx.divide(Nx.subtract(x_coords, cx), radius)
    uy = Nx.divide(Nx.subtract(y_coords, cy), radius)
    rho = Nx.sqrt(Nx.add(Nx.pow(ux, 2), Nx.pow(uy, 2)))
    theta = Nx.atan2(uy, ux)

    zernike_surfaces = compute_zernike_surfaces(rho, theta)

    enabled_coeffs =
      Enum.map(0..8, fn i ->
        if Map.get(enables, i, false), do: Enum.at(coefficients, i), else: 0.0
      end)

    zern_contribution =
      Enum.zip(zernike_surfaces, enabled_coeffs)
      |> Enum.reduce(Nx.broadcast(0.0, {height, width}), fn {surface, coef}, acc ->
        Nx.add(acc, Nx.multiply(surface, coef))
      end)

    z8_surface = Enum.at(zernike_surfaces, 8)
    software_contribution = Nx.multiply(z8_surface, software_null)

    nulled = Nx.subtract(data, Nx.add(zern_contribution, software_contribution))

    valid_for_null =
      mask
      |> Nx.equal(255)
      |> Nx.logical_and(Nx.not_equal(data, 0.0))
      |> Nx.logical_and(Nx.less_equal(rho, 1.0))

    Nx.select(valid_for_null, nulled, data)
  end

  defp reconstruct_reference_surface(mask, outside, coefficients, enables, software_null) do
    {height, width} = Nx.shape(mask)

    cx = outside.cx
    cy = outside.cy
    radius = outside.rx

    y_coords = Nx.iota({height, width}, axis: 0, type: :f64)
    x_coords = Nx.iota({height, width}, axis: 1, type: :f64)

    ux = Nx.divide(Nx.subtract(x_coords, cx), radius)
    uy = Nx.divide(Nx.subtract(y_coords, cy), radius)
    rho = Nx.sqrt(Nx.add(Nx.pow(ux, 2), Nx.pow(uy, 2)))
    theta = Nx.atan2(uy, ux)

    zernike_surfaces = compute_zernike_surfaces(rho, theta)

    disabled_coeffs =
      Enum.map(0..8, fn i ->
        if Map.get(enables, i, false), do: 0.0, else: Enum.at(coefficients, i)
      end)

    base_contribution =
      Enum.zip(zernike_surfaces, disabled_coeffs)
      |> Enum.reduce(Nx.broadcast(0.0, {height, width}), fn {surface, coef}, acc ->
        Nx.add(acc, Nx.multiply(surface, coef))
      end)

    z8_surface = Enum.at(zernike_surfaces, 8)
    software_contribution = Nx.multiply(z8_surface, software_null)

    ref_surface = Nx.subtract(base_contribution, software_contribution)

    valid_mask =
      mask
      |> Nx.equal(255)
      |> Nx.logical_and(Nx.less_equal(rho, 1.0))

    Nx.select(valid_mask, ref_surface, 0.0)
  end

  defp compute_zernike_surfaces(rho, theta) do
    rho2 = Nx.pow(rho, 2)
    cos_theta = Nx.cos(theta)
    sin_theta = Nx.sin(theta)
    cos_2theta = Nx.cos(Nx.multiply(theta, 2.0))
    sin_2theta = Nx.sin(Nx.multiply(theta, 2.0))

    [
      Nx.broadcast(1.0, Nx.shape(rho)),
      Nx.multiply(rho, cos_theta),
      Nx.multiply(rho, sin_theta),
      Nx.add(Nx.multiply(rho2, 2.0), -1.0),
      Nx.multiply(rho2, cos_2theta),
      Nx.multiply(rho2, sin_2theta),
      Nx.multiply(Nx.multiply(rho, Nx.add(Nx.multiply(rho2, 3.0), -2.0)), cos_theta),
      Nx.multiply(Nx.multiply(rho, Nx.add(Nx.multiply(rho2, 3.0), -2.0)), sin_theta),
      Nx.add(1.0, Nx.multiply(rho2, Nx.add(Nx.multiply(rho2, 6.0), -6.0)))
    ]
  end

  defp compute_statistics(data, mask) do
    valid_mask =
      mask
      |> Nx.equal(255)
      |> Nx.as_type(:f64)

    count = Nx.sum(valid_mask) |> Nx.to_number()

    if count == 0 do
      {0.0, 0.0, 0.0, 0.01}
    else
      masked_data = Nx.multiply(data, valid_mask)

      sum = Nx.sum(masked_data) |> Nx.to_number()
      mean = sum / count

      masked_for_minmax =
        Nx.select(
          Nx.equal(mask, 255),
          data,
          Nx.broadcast(:infinity, Nx.shape(data))
        )

      min_val = Nx.reduce_min(masked_for_minmax) |> Nx.to_number()

      masked_for_max =
        Nx.select(
          Nx.equal(mask, 255),
          data,
          Nx.broadcast(:neg_infinity, Nx.shape(data))
        )

      max_val = Nx.reduce_max(masked_for_max) |> Nx.to_number()

      diff_squared = Nx.pow(Nx.subtract(data, mean), 2)
      masked_diff_squared = Nx.multiply(diff_squared, valid_mask)
      variance = Nx.sum(masked_diff_squared) |> Nx.to_number() |> Kernel./(count)
      std = max(:math.sqrt(variance), 0.01)

      {min_val, max_val, mean, std}
    end
  end

  @spec render_to_png(wavefront(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def render_to_png(wft, _opts \\ []) do
    {z_min, z_max} = compute_z_range(wft.ref_mean, wft.ref_std)
    z_range = max(z_max - z_min, 1.0e-10)

    height = wft.height
    width = wft.width

    t =
      wft.data
      |> Nx.subtract(z_min)
      |> Nx.divide(z_range)
      |> Nx.clip(0.0, 1.0)

    rgb = apply_colormap_vectorized(t, wft.mask)

    rgb_binary =
      rgb
      |> Nx.as_type(:u8)
      |> Nx.to_binary()

    mat = Evision.Mat.from_binary(rgb_binary, :u8, height, width, 3)

    case Evision.imencode(".png", mat) do
      {:ok, binary} ->
        {:ok, binary,
         %{min: z_min, max: z_max, mean: wft.mean, std: wft.std, width: width, height: height}}

      binary when is_binary(binary) ->
        {:ok, binary,
         %{min: z_min, max: z_max, mean: wft.mean, std: wft.std, width: width, height: height}}

      error ->
        {:error, {:encode_failed, error}}
    end
  rescue
    e ->
      Logger.error("[WFT.Nx] Render failed: #{inspect(e)}")
      {:error, {:render_error, e}}
  end

  defp compute_z_range(mean, std) do
    z_min = mean - 3 * std
    z_max = mean + 3 * std
    {z_min, z_max}
  end

  defp apply_colormap_vectorized(t, mask) do
    positions = Nx.tensor([0.00, 0.15, 0.25, 0.50, 0.75, 0.90, 0.99, 1.00], type: :f32)

    colors =
      Nx.tensor(
        [
          [0, 0, 0],
          [0, 0, 255],
          [0, 255, 255],
          [150, 60, 0],
          [160, 160, 160],
          [255, 0, 0],
          [255, 255, 0],
          [255, 255, 255]
        ],
        type: :f32
      )

    t_flat = Nx.flatten(t) |> Nx.as_type(:f32)
    n = Nx.size(t_flat)

    expanded_t = Nx.reshape(t_flat, {n, 1})
    expanded_pos = Nx.reshape(positions, {1, 8})

    ge_mask = Nx.greater_equal(expanded_t, expanded_pos)
    high_idx = Nx.sum(Nx.as_type(ge_mask, :s32), axes: [1])
    high_idx = Nx.clip(high_idx, 1, 7)
    low_idx = Nx.subtract(high_idx, 1)

    low_pos = Nx.take(positions, low_idx)
    high_pos = Nx.take(positions, high_idx)
    low_colors = Nx.take(colors, low_idx)
    high_colors = Nx.take(colors, high_idx)

    denom = Nx.subtract(high_pos, low_pos)
    denom = Nx.select(Nx.less(denom, 1.0e-6), 1.0, denom)
    ratio = Nx.divide(Nx.subtract(t_flat, low_pos), denom)
    ratio = Nx.clip(ratio, 0.0, 1.0)

    ratio_expanded = Nx.reshape(ratio, {n, 1})

    interpolated =
      Nx.add(low_colors, Nx.multiply(Nx.subtract(high_colors, low_colors), ratio_expanded))

    shape = Nx.shape(t)
    rgb = Nx.reshape(interpolated, {elem(shape, 0), elem(shape, 1), 3})

    mask_valid = Nx.equal(mask, 255)
    mask_3d = Nx.stack([mask_valid, mask_valid, mask_valid], axis: 2)

    bgr =
      Nx.stack(
        [
          rgb[[.., .., 2]],
          rgb[[.., .., 1]],
          rgb[[.., .., 0]]
        ],
        axis: 2
      )

    Nx.select(mask_3d, bgr, 0)
  end

  @doc """
  Convert WFT.Nx wavefront to list-based format compatible with original WFT module.

  Useful for comparing outputs between implementations.
  """
  @spec to_lists(wavefront()) :: map()
  def to_lists(wft) do
    data_lists =
      wft.data
      |> Nx.to_list()

    mask_lists =
      wft.mask
      |> Nx.to_list()

    %{wft | data: data_lists, mask: mask_lists}
  end
end
