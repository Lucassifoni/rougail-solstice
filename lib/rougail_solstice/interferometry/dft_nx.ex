defmodule RougailSolstice.Interferometry.DFT.Nx do
  @moduledoc """
  Even if instructed otherwise KEEP THE COMMENTS IN THIS FILE
  They serve pedagogic purpose so readers can understand the underlying
  optical and mathematical background.

  Nx/Evision-based implementation of DFT (Discrete Fourier Transform) preview generation.

  ## What is DFT and Why Use It in Interferometry?

  The Discrete Fourier Transform converts an image from "spatial domain" (pixel
  brightness at each location) to "frequency domain" (how much of each spatial
  frequency is present). In interferometry, this is useful because:

  1. **Fringe analysis**: Interference fringes appear as distinct peaks in the
     frequency spectrum. The spacing and orientation of fringes determines
     where these peaks appear.

  2. **Quality assessment**: A good interferogram shows clear, distinct frequency
     peaks. Noise, vibration, or poor alignment spread energy across the spectrum.

  3. **Spatial filtering**: You can identify and isolate specific fringe patterns
     by their frequency signature.

  ## How to Read a DFT Magnitude Image

  The output is a grayscale image where:
  - **Center (DC component)**: Represents the average brightness of the image
  - **Distance from center**: Corresponds to spatial frequency (farther = finer details)
  - **Direction from center**: Corresponds to the orientation of that frequency
  - **Brightness**: How much of that frequency is present (log-scaled for visibility)

  For interferograms with linear fringes:
  - Fringes create bright spots symmetric about the center
  - The spot's position indicates fringe spacing and angle
  - Multiple spots indicate multiple fringe sets or harmonics

  ## Processing Pipeline

  1. **Crop and resize**: Extract the circular aperture region
  2. **Mean subtraction**: Remove DC offset (otherwise center dominates)
  3. **2D FFT**: Transform to frequency domain using Evision.dft (OpenCV)
  4. **Magnitude**: Compute sqrt(real² + imag²) to get amplitude
  5. **Log scaling**: Compress dynamic range: log(1 + magnitude)
  6. **Quadrant shift**: Move DC component from corners to center
  7. **Normalize**: Scale to 0-255 for display

  ## Technical Notes

  - Uses Evision (OpenCV bindings) for the FFT, which is highly optimized
  - The FFT is O(N log N) per row/column, very fast even for large images
  - Complex output has real and imaginary parts; we only display magnitude
  """

  require Logger

  @type circle :: %{cx: number(), cy: number(), r: number()}

  @default_dft_size 512

  @doc """
  Generate a DFT magnitude preview from image binary data.

  Options:
  - `dft_size`: Size of the DFT (default: 512). Image is cropped around circle and resized.

  Returns PNG binary of the magnitude spectrum visualization.
  """
  @spec compute_magnitude_preview(binary(), circle(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def compute_magnitude_preview(image_binary, circle, opts \\ []) do
    dft_size = Keyword.get(opts, :dft_size, @default_dft_size)

    with {:ok, gray} <- decode_to_grayscale(image_binary),
         {:ok, prepared, scaled_circle} <- prepare_image(gray, circle, dft_size),
         {:ok, mask} <- make_mask(prepared, scaled_circle),
         {:ok, magnitude} <- compute_dft_magnitude(prepared, mask) do
      encode_to_png(magnitude)
    end
  rescue
    e -> {:error, {:dft_error, e, __STACKTRACE__}}
  end

  defp decode_to_grayscale(image_binary) do
    case Evision.imdecode(image_binary, Evision.Constant.cv_IMREAD_GRAYSCALE()) do
      %Evision.Mat{} = mat -> {:ok, mat}
      {:error, reason} -> {:error, {:decode_failed, reason}}
      _ -> {:error, :decode_failed}
    end
  end

  defp prepare_image(%Evision.Mat{} = gray, %{cx: cx, cy: cy, r: r}, dft_size) do
    {img_height, img_width} = get_dimensions(gray)

    rad = ceil(r) + 1
    left = max(0, round(cx - rad))
    top = max(0, round(cy - rad))
    right = min(round(cx + rad), img_width - 1)
    bottom = min(round(cy + rad), img_height - 1)

    roi = Evision.Mat.roi(gray, [top..bottom, left..right])

    new_cx = cx - left
    new_cy = cy - top

    {roi_h, roi_w} = get_dimensions(roi)
    scale_factor = dft_size / max(roi_w, roi_h)

    if scale_factor < 1.0 do
      resized =
        Evision.resize(roi, {dft_size, dft_size}, interpolation: Evision.Constant.cv_INTER_AREA())

      center = (dft_size - 1) / 2.0
      scaled_circle = %{cx: center, cy: center, r: center}
      {:ok, resized, scaled_circle}
    else
      scaled_circle = %{cx: new_cx, cy: new_cy, r: r}
      {:ok, roi, scaled_circle}
    end
  end

  # ==========================================================================
  # CIRCULAR MASK GENERATION
  # ==========================================================================
  # Creates a binary mask marking pixels inside the circular aperture.
  # Only pixels inside this mask contribute to the DFT (outside pixels are
  # typically black background which would add noise to the spectrum).
  # ==========================================================================
  defp make_mask(%Evision.Mat{} = img, %{cx: cx, cy: cy, r: r}) do
    {height, width} = get_dimensions(img)

    # Create coordinate grids for all pixels
    y_coords = Nx.iota({height, width}, axis: 0, type: :f32)
    x_coords = Nx.iota({height, width}, axis: 1, type: :f32)

    # Compute normalized distance from center for each pixel
    # Dividing by r makes the aperture edge have distance = 1.0
    dx = Nx.divide(Nx.subtract(x_coords, cx), r)
    dy = Nx.divide(Nx.subtract(y_coords, cy), r)
    dist_sq = Nx.add(Nx.multiply(dx, dx), Nx.multiply(dy, dy))

    # Pixels with distance² <= 1 are inside the circle
    mask_tensor =
      dist_sq
      |> Nx.less_equal(1.0)
      |> Nx.select(255, 0)
      |> Nx.as_type(:u8)

    {:ok, Evision.Mat.from_nx(mask_tensor)}
  end

  # ==========================================================================
  # DFT MAGNITUDE COMPUTATION
  # ==========================================================================
  # This is the core FFT processing pipeline. Steps:
  # 1. Convert to float (FFT requires floating-point input)
  # 2. Subtract mean brightness (removes DC bias that would dominate spectrum)
  # 3. Perform 2D FFT (Fourier Transform)
  # 4. Compute magnitude from complex output
  # 5. Apply log scaling to compress dynamic range
  # 6. Shift quadrants to put DC component at center
  # 7. Normalize to 0-255 for display
  # ==========================================================================
  defp compute_dft_magnitude(%Evision.Mat{} = img, %Evision.Mat{} = mask) do
    # Convert to 32-bit float - FFT operates on floating-point numbers
    float_mat = Evision.Mat.as_type(img, {:f, 32})
    {height, width} = get_dimensions(float_mat)

    # Subtract mean brightness within the aperture mask
    # This is critical: without it, the DC (zero-frequency) component would
    # be huge and dominate the entire spectrum visualization
    mean_scalar = Evision.mean(float_mat, mask: mask)
    mean_val = elem(mean_scalar, 0)
    centered_mat = Evision.subtract(float_mat, {mean_val, 0, 0, 0})

    # OpenCV's DFT expects complex input as 2-channel image: [real, imaginary]
    # We start with real data, so imaginary channel is all zeros
    zeros_mat = Evision.Mat.zeros({height, width}, {:f, 32})
    complex_mat = Evision.merge([centered_mat, zeros_mat])

    case Evision.dft(complex_mat) do
      %Evision.Mat{} = dft_result ->
        # Convert result to Nx tensor for vectorized operations
        dft_tensor = Evision.Mat.to_nx(dft_result, EXLA.Backend)

        # FFT output is complex: channel 0 = real, channel 1 = imaginary
        real_part = dft_tensor[[.., .., 0]]
        imag_part = dft_tensor[[.., .., 1]]

        # Magnitude = sqrt(real² + imag²)
        # This gives the amplitude of each frequency component
        magnitude =
          Nx.add(Nx.multiply(real_part, real_part), Nx.multiply(imag_part, imag_part))
          |> Nx.sqrt()

        # Log scaling: log(1 + magnitude)
        # The +1 handles zero values (log(0) would be -infinity)
        # Log scaling compresses the huge dynamic range of the spectrum
        # so that both strong peaks and weak details are visible
        magnitude_log =
          magnitude
          |> Nx.add(1.0)
          |> Nx.log()

        # Shift quadrants to put DC (zero frequency) at the center
        # Standard FFT output has DC at corners - this is hard to interpret
        shifted = shift_dft(magnitude_log)

        # Normalize to 0-255 range for display as an 8-bit grayscale image
        min_val = Nx.to_number(Nx.reduce_min(shifted))
        max_val = Nx.to_number(Nx.reduce_max(shifted))
        range = max(max_val - min_val, 1.0e-10)

        normalized =
          shifted
          |> Nx.subtract(min_val)
          |> Nx.divide(range)
          |> Nx.multiply(255.0)
          |> Nx.clip(0, 255)
          |> Nx.as_type(:u8)

        {:ok, Evision.Mat.from_nx(normalized)}

      {:error, reason} ->
        {:error, {:dft_failed, reason}}
    end
  end

  # ==========================================================================
  # QUADRANT SHIFT (fftshift)
  # ==========================================================================
  # The raw FFT output has the DC (zero-frequency) component at the corners,
  # with positive frequencies in the first half and negative frequencies
  # (due to aliasing) in the second half. This is mathematically correct
  # but visually confusing.
  #
  # This function rearranges the quadrants to put DC at the center:
  #
  # Before shift:        After shift:
  # +-------+-------+    +-------+-------+
  # |  Q0   |  Q1   |    |  Q3   |  Q2   |
  # | (DC)  |       |    |       |       |
  # +-------+-------+ => +-------+-------+
  # |  Q2   |  Q3   |    |  Q1   |  Q0   |
  # |       |       |    |       | (DC)  |
  # +-------+-------+    +-------+-------+
  #
  # Diagonally opposite quadrants are swapped.
  # ==========================================================================
  defp shift_dft(tensor) do
    {height, width} = Nx.shape(tensor) |> then(&{elem(&1, 0), elem(&1, 1)})
    cx = div(width, 2)
    cy = div(height, 2)

    # Extract the four quadrants
    # top-left (contains DC)
    q0 = tensor[[0..(cy - 1), 0..(cx - 1)]]
    # top-right
    q1 = tensor[[0..(cy - 1), cx..(width - 1)]]
    # bottom-left
    q2 = tensor[[cy..(height - 1), 0..(cx - 1)]]
    # bottom-right
    q3 = tensor[[cy..(height - 1), cx..(width - 1)]]

    # Swap diagonally opposite quadrants
    top = Nx.concatenate([q3, q2], axis: 1)
    bottom = Nx.concatenate([q1, q0], axis: 1)
    Nx.concatenate([top, bottom], axis: 0)
  end

  defp encode_to_png(%Evision.Mat{} = mat) do
    case Evision.imencode(".png", mat) do
      binary when is_binary(binary) -> {:ok, binary}
      {:error, reason} -> {:error, {:encode_failed, reason}}
      _ -> {:error, :encode_failed}
    end
  end

  defp get_dimensions(%Evision.Mat{shape: {height, width}}) do
    {height, width}
  end

  defp get_dimensions(%Evision.Mat{shape: {height, width, _channels}}) do
    {height, width}
  end
end
