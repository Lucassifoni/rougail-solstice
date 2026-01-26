defmodule RougailSolstice.Interferometry.WFT.Nx do
  @moduledoc """
  Nx-accelerated implementation of WFT (WaveFronT) parsing and rendering.

  ## What is a Wavefront File?

  A WFT (WaveFronT) file contains the measured optical surface error of a mirror
  or lens, extracted from interferometric analysis. Each pixel value represents
  the deviation from a perfect surface at that point, typically in units of
  "waves" (fractions of the test wavelength).

  The file format contains:
  - Dimensions (width × height)
  - Per-pixel surface deviation values (0 = invalid/masked pixel)
  - Metadata: aperture circle, diameter, radius of curvature, wavelength

  ## Processing Pipeline

  When parsing a WFT file, this module performs:

  1. **Parse dimensions and data**: Read width, height, and the 2D grid of values
  2. **Build validity mask**: Mark pixels with actual data (non-zero values)
  3. **Parse metadata**: Extract aperture geometry, physical dimensions, wavelength
  4. **Zernike fitting**: Decompose the wavefront into Zernike polynomials
  5. **Zernike nulling**: Subtract alignment-related aberrations (tilt, focus, etc.)
  6. **Software null**: Apply theoretical spherical aberration correction for
     non-spherical test geometry (conic constant correction)
  7. **Compute statistics**: Calculate min, max, mean, standard deviation

  ## What is "Nulling"?

  Raw wavefront data includes many sources of error:
  - **Piston**: Overall offset (irrelevant to image quality)
  - **Tilt**: Alignment error of the test setup
  - **Defocus**: Focus adjustment error
  - **Astigmatism from setup**: Test geometry, not the optic itself
  - **Actual mirror errors**: What we want to measure!

  "Nulling" means subtracting the alignment-related aberrations (piston, tilt,
  focus, astigmatism) so that only the inherent mirror figure error remains.
  The `enables` map controls which Zernike terms are nulled (subtracted).

  ## Software Null (Conic Correction)

  When testing a parabolic or hyperbolic mirror at center of curvature,
  the geometry introduces spherical aberration even for a perfect mirror.
  The "software null" calculates and removes this expected spherical component
  based on the mirror's diameter, radius of curvature, wavelength, and conic
  constant.

  Formula: Z8_null = (D^4 × 10^6) / (384 × ROC^3 × λ) × conic

  Where:
  - D = mirror diameter (mm)
  - ROC = radius of curvature (mm)
  - λ = wavelength (nm)
  - conic = conic constant (-1 for parabola, 0 for sphere)

  ## Rendering

  The `render_to_png/2` function converts the processed wavefront to a false-color
  PNG image using a custom colormap. The color scale is based on statistical
  analysis (mean ± 3σ) to show meaningful detail.
  """

  require Logger

  alias RougailSolstice.Interferometry.Zernike

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

  @default_zernike_terms 9

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
    num_zernike_terms = Keyword.get(opts, :zernike_terms, @default_zernike_terms)
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
            apply_zernike_null(data, mask, outside, software_null, num_zernike_terms)

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

  # ==========================================================================
  # SOFTWARE NULL COMPUTATION
  # ==========================================================================
  # When testing a conic mirror (parabola, hyperbola) at its center of curvature,
  # the test geometry introduces spherical aberration even if the mirror is perfect.
  # This is because the reference wavefront from the interferometer is spherical,
  # but the mirror deviates from a sphere by design.
  #
  # The software null calculates the expected Z8 (primary spherical) coefficient
  # so it can be subtracted from the measured data, leaving only the manufacturing
  # errors.
  #
  # Formula derivation:
  # For a conic mirror tested at center of curvature, the wavefront error
  # follows the Seidel aberration formula. The Z8 Zernike coefficient is:
  #
  #   Z8 = (D^4 × 10^6) / (384 × ROC^3 × λ) × conic_constant
  #
  # Where:
  #   D = mirror diameter in mm
  #   ROC = radius of curvature in mm
  #   λ = test wavelength in nm
  #   conic_constant = -1 for parabola, 0 for sphere, -k for hyperbola
  #
  # For a sphere (conic = 0), no correction is needed.
  # For a parabola (conic = -1), significant negative spherical is expected.
  # ==========================================================================
  defp compute_software_null(nil, _roc, _lambda, _conic), do: 0.0
  defp compute_software_null(_diameter, nil, _lambda, _conic), do: 0.0
  defp compute_software_null(_diameter, _roc, nil, _conic), do: 0.0
  defp compute_software_null(_diameter, _roc, _lambda, 0.0), do: 0.0

  defp compute_software_null(diameter, roc, lambda, conic) do
    # Base Z8 coefficient from Seidel theory (before conic scaling)
    # The 10^6 factor converts units to waves
    z8_computed = :math.pow(diameter, 4) * 1_000_000.0 / (384.0 * :math.pow(roc, 3) * lambda)
    # Scale by conic constant: parabola=-1 gives full correction, sphere=0 gives none
    z8_computed * conic
  end

  # ==========================================================================
  # ZERNIKE NULLING PIPELINE
  # ==========================================================================
  # This function orchestrates the wavefront nulling process:
  # 1. Fit Zernike polynomials to the raw data (find how much of each aberration)
  # 2. Subtract "enabled" aberrations (alignment errors we want to remove)
  # 3. Apply the software null (theoretical spherical aberration from test geometry)
  # 4. Reconstruct a "reference surface" from non-nulled terms (the actual mirror errors)
  # ==========================================================================
  defp apply_zernike_null(data, mask, outside, software_null, num_terms) do
    # Step 1: Fit Zernike polynomials to find coefficients
    # This tells us "how much" of each aberration type is present
    coefficients = Zernike.fit(data, mask, outside, num_terms)

    # Define which terms to subtract (enables map)
    enables = default_null_enables(num_terms)

    {height, width} = Nx.shape(data)
    {rho, theta} = Zernike.polar_grid(width, height, outside.cx, outside.cy, outside.rx)

    # Step 2: Subtract enabled Zernike terms + software null from the data
    nulled_data = subtract_zernikes(data, mask, rho, theta, coefficients, enables, software_null)

    # Step 3: Build reference surface from the terms we DIDN'T null
    # This represents the actual mirror figure error
    reference_surface =
      reconstruct_reference_surface(mask, rho, theta, coefficients, enables, software_null)

    {nulled_data, reference_surface}
  end

  # ==========================================================================
  # DEFAULT NULL ENABLES
  # ==========================================================================
  # Defines which Zernike terms should be subtracted ("nulled") from the wavefront.
  #
  # true  = subtract this term (it's an alignment error, not a mirror defect)
  # false = keep this term (it represents actual mirror figure error)
  #
  # Standard nulling removes:
  #   Z0: Piston (constant offset, meaningless)
  #   Z1, Z2: Tilt X/Y (alignment of mirror in test setup)
  #   Z3: Defocus (focus adjustment error)
  #   Z6, Z7: Coma X/Y (often from alignment, though can be mirror error)
  #
  # Standard nulling keeps:
  #   Z4, Z5: Astigmatism (usually a real mirror defect)
  #   Z8: Primary Spherical (the most important mirror figure error!)
  #   Z9+: Higher-order terms (real surface details)
  # ==========================================================================
  defp default_null_enables(num_terms) do
    base_enables = %{
      # Piston - always null (meaningless offset)
      0 => true,
      # Tilt X - alignment error
      1 => true,
      # Tilt Y - alignment error
      2 => true,
      # Defocus - focus adjustment
      3 => true,
      # Astigmatism 0° - usually real mirror error
      4 => false,
      # Astigmatism 45° - usually real mirror error
      5 => false,
      # Coma X - often alignment (can be disabled if coma is real)
      6 => true,
      # Coma Y - often alignment
      7 => true,
      # Primary Spherical - THE key mirror figure term, never null
      8 => false
    }

    # Higher-order terms (Z9+) are not nulled by default
    Enum.reduce(9..(num_terms - 1), base_enables, fn i, acc ->
      Map.put(acc, i, false)
    end)
  end

  # ==========================================================================
  # ZERNIKE SUBTRACTION
  # ==========================================================================
  # Subtracts the "enabled" Zernike terms from the wavefront data.
  # This removes alignment-related aberrations, leaving only the actual mirror errors.
  #
  # The subtracted surface is:
  #   contribution = Σ (enabled_coef[i] × Z_i) + software_null × Z8
  #
  # Where enabled_coef[i] = coefficient[i] if enabled, else 0.
  # The software_null term is always subtracted from Z8 regardless of enable state.
  # ==========================================================================
  defp subtract_zernikes(data, mask, rho, theta, coefficients, enables, software_null) do
    {height, width} = Nx.shape(data)
    num_terms = length(coefficients)

    # Pre-compute all Zernike surfaces (one 2D surface per term)
    zernike_surfaces = Zernike.compute_surfaces(rho, theta, num_terms)

    # Build coefficient array with zeros for disabled terms
    enabled_coeffs =
      Enum.map(0..(num_terms - 1), fn i ->
        if Map.get(enables, i, false), do: Enum.at(coefficients, i), else: 0.0
      end)

    # Sum up the contribution of all enabled Zernike terms
    # contribution = c0×Z0 + c1×Z1 + ... where ci=0 if not enabled
    zern_contribution =
      Enum.zip(zernike_surfaces, enabled_coeffs)
      |> Enum.reduce(Nx.broadcast(0.0, {height, width}), fn {surface, coef}, acc ->
        Nx.add(acc, Nx.multiply(surface, coef))
      end)

    # Add software null contribution (always applied to Z8 / spherical aberration)
    z8_surface = Enum.at(zernike_surfaces, 8)
    software_contribution = Nx.multiply(z8_surface, software_null)

    # Subtract both contributions from the raw data
    nulled = Nx.subtract(data, Nx.add(zern_contribution, software_contribution))

    # Only apply nulling to valid pixels inside the aperture
    valid_for_null =
      mask
      |> Nx.equal(255)
      |> Nx.logical_and(Nx.not_equal(data, 0.0))
      |> Nx.logical_and(Nx.less_equal(rho, 1.0))

    Nx.select(valid_for_null, nulled, data)
  end

  # ==========================================================================
  # REFERENCE SURFACE RECONSTRUCTION
  # ==========================================================================
  # Reconstructs the "reference surface" - the wavefront that represents
  # the actual mirror errors (terms we DIDN'T null).
  #
  # This is the inverse of what we subtracted: it shows the aberrations
  # that remain after nulling, which represent the actual optical quality.
  #
  # Used to compute statistics on the processed wavefront.
  # ==========================================================================
  defp reconstruct_reference_surface(mask, rho, theta, coefficients, enables, software_null) do
    {height, width} = Nx.shape(mask)
    num_terms = length(coefficients)

    zernike_surfaces = Zernike.compute_surfaces(rho, theta, num_terms)

    # Use coefficients for DISABLED terms only (the ones we kept)
    disabled_coeffs =
      Enum.map(0..(num_terms - 1), fn i ->
        if Map.get(enables, i, false), do: 0.0, else: Enum.at(coefficients, i)
      end)

    # Sum up contribution of non-nulled Zernike terms
    base_contribution =
      Enum.zip(zernike_surfaces, disabled_coeffs)
      |> Enum.reduce(Nx.broadcast(0.0, {height, width}), fn {surface, coef}, acc ->
        Nx.add(acc, Nx.multiply(surface, coef))
      end)

    # Subtract software null from reference (it was subtracted from data, so
    # we need to account for it here too for the reference to match)
    z8_surface = Enum.at(zernike_surfaces, 8)
    software_contribution = Nx.multiply(z8_surface, software_null)

    ref_surface = Nx.subtract(base_contribution, software_contribution)

    # Apply validity mask
    valid_mask =
      mask
      |> Nx.equal(255)
      |> Nx.logical_and(Nx.less_equal(rho, 1.0))

    Nx.select(valid_mask, ref_surface, 0.0)
  end

  # ==========================================================================
  # MASKED STATISTICS COMPUTATION
  # ==========================================================================
  # Computes min, max, mean, and standard deviation over only the valid pixels
  # (inside the aperture mask). Invalid pixels are excluded from all calculations.
  #
  # Returns: {min, max, mean, std_dev}
  # ==========================================================================
  defp compute_statistics(data, mask) do
    # Convert mask to float for mathematical operations (255 → 1.0, 0 → 0.0)
    valid_mask =
      mask
      |> Nx.equal(255)
      |> Nx.as_type(:f64)

    count = Nx.sum(valid_mask) |> Nx.to_number()

    if count == 0 do
      {0.0, 0.0, 0.0, 0.01}
    else
      # MEAN: sum of valid values / count of valid pixels
      masked_data = Nx.multiply(data, valid_mask)
      sum = Nx.sum(masked_data) |> Nx.to_number()
      mean = sum / count

      # MIN: replace invalid pixels with +infinity so they don't affect reduce_min
      masked_for_minmax =
        Nx.select(
          Nx.equal(mask, 255),
          data,
          Nx.broadcast(:infinity, Nx.shape(data))
        )

      min_val = Nx.reduce_min(masked_for_minmax) |> Nx.to_number()

      # MAX: replace invalid pixels with -infinity so they don't affect reduce_max
      masked_for_max =
        Nx.select(
          Nx.equal(mask, 255),
          data,
          Nx.broadcast(:neg_infinity, Nx.shape(data))
        )

      max_val = Nx.reduce_max(masked_for_max) |> Nx.to_number()

      # STANDARD DEVIATION: sqrt(mean((x - mean)²))
      # Only computed over valid pixels
      diff_squared = Nx.pow(Nx.subtract(data, mean), 2)
      masked_diff_squared = Nx.multiply(diff_squared, valid_mask)
      variance = Nx.sum(masked_diff_squared) |> Nx.to_number() |> Kernel./(count)
      # Minimum 0.01 to avoid division by zero
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

  # ==========================================================================
  # Z-RANGE COMPUTATION FOR DISPLAY
  # ==========================================================================
  # Determines the value range for the color scale using mean ± 3σ.
  # This captures 99.7% of values in a normal distribution, which works well
  # for wavefront data that typically has a Gaussian-like distribution.
  #
  # Using statistics rather than raw min/max prevents outliers from
  # compressing the useful part of the color scale.
  # ==========================================================================
  defp compute_z_range(mean, std) do
    z_min = mean - 3 * std
    z_max = mean + 3 * std
    {z_min, z_max}
  end

  # ==========================================================================
  # VECTORIZED FALSE-COLOR COLORMAP
  # ==========================================================================
  # Converts normalized wavefront values [0,1] to RGB colors using a custom
  # colormap designed for optical surface visualization.
  #
  # The colormap is defined by control points (positions) and their colors:
  #
  #   Position   Color           Meaning in optical testing
  #   --------   -----           --------------------------
  #   0.00       Black           Minimum value (worst low)
  #   0.15       Blue            Significant low zone
  #   0.25       Cyan            Moderate low zone
  #   0.50       Brown/Orange    Near neutral (mid-value)
  #   0.75       Gray            Moderate high zone
  #   0.90       Red             Significant high zone
  #   0.99       Yellow          Near maximum (worst high)
  #   1.00       White           Maximum value
  #
  # Values between control points are linearly interpolated.
  #
  # Algorithm (vectorized for performance):
  # 1. Find which segment each pixel falls into (between which control points)
  # 2. Compute interpolation ratio within that segment
  # 3. Linearly interpolate RGB between the two bounding colors
  # ==========================================================================
  defp apply_colormap_vectorized(t, mask) do
    # Colormap control points (normalized positions 0-1)
    positions = Nx.tensor([0.00, 0.15, 0.25, 0.50, 0.75, 0.90, 0.99, 1.00], type: :f32)

    # RGB colors at each control point
    colors =
      Nx.tensor(
        [
          # Black at 0.00
          [0, 0, 0],
          # Blue at 0.15
          [0, 0, 255],
          # Cyan at 0.25
          [0, 255, 255],
          # Brown/Orange at 0.50
          [150, 60, 0],
          # Gray at 0.75
          [160, 160, 160],
          # Red at 0.90
          [255, 0, 0],
          # Yellow at 0.99
          [255, 255, 0],
          # White at 1.00
          [255, 255, 255]
        ],
        type: :f32
      )

    # Flatten for vectorized processing
    t_flat = Nx.flatten(t) |> Nx.as_type(:f32)
    n = Nx.size(t_flat)

    # Find which colormap segment each pixel falls into
    # ge_mask[i,j] = true if pixel[i] >= position[j]
    expanded_t = Nx.reshape(t_flat, {n, 1})
    expanded_pos = Nx.reshape(positions, {1, 8})

    ge_mask = Nx.greater_equal(expanded_t, expanded_pos)
    # high_idx = count of positions that pixel value exceeds
    # This tells us which segment the pixel falls into
    high_idx = Nx.sum(Nx.as_type(ge_mask, :s32), axes: [1])
    # Clamp to valid range
    high_idx = Nx.clip(high_idx, 1, 7)
    low_idx = Nx.subtract(high_idx, 1)

    # Get the bounding positions and colors for each pixel's segment
    low_pos = Nx.take(positions, low_idx)
    high_pos = Nx.take(positions, high_idx)
    low_colors = Nx.take(colors, low_idx)
    high_colors = Nx.take(colors, high_idx)

    # Compute interpolation ratio within each segment
    # ratio = (value - low_pos) / (high_pos - low_pos)
    denom = Nx.subtract(high_pos, low_pos)
    # Avoid divide by zero
    denom = Nx.select(Nx.less(denom, 1.0e-6), 1.0, denom)
    ratio = Nx.divide(Nx.subtract(t_flat, low_pos), denom)
    ratio = Nx.clip(ratio, 0.0, 1.0)

    # Linear interpolation: color = low + ratio * (high - low)
    ratio_expanded = Nx.reshape(ratio, {n, 1})

    interpolated =
      Nx.add(low_colors, Nx.multiply(Nx.subtract(high_colors, low_colors), ratio_expanded))

    # Reshape back to image dimensions
    shape = Nx.shape(t)
    rgb = Nx.reshape(interpolated, {elem(shape, 0), elem(shape, 1), 3})

    # Apply mask (invalid pixels become black)
    mask_valid = Nx.equal(mask, 255)
    mask_3d = Nx.stack([mask_valid, mask_valid, mask_valid], axis: 2)

    # Convert RGB to BGR for OpenCV/Evision compatibility
    bgr =
      Nx.stack(
        [
          # B = original R
          rgb[[.., .., 2]],
          # G stays G
          rgb[[.., .., 1]],
          # R = original B
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
