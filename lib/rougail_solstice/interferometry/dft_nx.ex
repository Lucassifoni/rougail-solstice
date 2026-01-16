defmodule RougailSolstice.Interferometry.DFT.Nx do
  @moduledoc """
  Nx/Evision-based implementation of DFT preview generation.

  This module provides DFT magnitude spectrum visualization using Evision.dft
  for the FFT and Nx for tensor operations. It serves as an alternative to the
  C++ sidecar/CLI implementation.

  Key operations:
  - Image cropping and resizing to DFT size
  - Image mean subtraction (masked)
  - Forward 2D DFT via Evision.dft
  - Magnitude computation and log scaling
  - Quadrant shift (center DC component)
  - Normalization and PNG encoding
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
         {:ok, magnitude} <- compute_dft_magnitude(prepared, mask),
         {:ok, png_binary} <- encode_to_png(magnitude) do
      {:ok, png_binary}
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

  defp make_mask(%Evision.Mat{} = img, %{cx: cx, cy: cy, r: r}) do
    {height, width} = get_dimensions(img)

    y_coords = Nx.iota({height, width}, axis: 0, type: :f32)
    x_coords = Nx.iota({height, width}, axis: 1, type: :f32)

    dx = Nx.divide(Nx.subtract(x_coords, cx), r)
    dy = Nx.divide(Nx.subtract(y_coords, cy), r)
    dist_sq = Nx.add(Nx.multiply(dx, dx), Nx.multiply(dy, dy))

    mask_tensor =
      dist_sq
      |> Nx.less_equal(1.0)
      |> Nx.select(255, 0)
      |> Nx.as_type(:u8)

    {:ok, Evision.Mat.from_nx(mask_tensor)}
  end

  defp compute_dft_magnitude(%Evision.Mat{} = img, %Evision.Mat{} = mask) do
    float_mat = Evision.Mat.as_type(img, {:f, 32})
    {height, width} = get_dimensions(float_mat)

    mean_scalar = Evision.mean(float_mat, mask: mask)
    mean_val = elem(mean_scalar, 0)

    centered_mat = Evision.subtract(float_mat, {mean_val, 0, 0, 0})

    zeros_mat = Evision.Mat.zeros({height, width}, {:f, 32})
    complex_mat = Evision.merge([centered_mat, zeros_mat])

    case Evision.dft(complex_mat) do
      %Evision.Mat{} = dft_result ->
        dft_tensor = Evision.Mat.to_nx(dft_result, EXLA.Backend)

        real_part = dft_tensor[[.., .., 0]]
        imag_part = dft_tensor[[.., .., 1]]

        magnitude =
          Nx.add(Nx.multiply(real_part, real_part), Nx.multiply(imag_part, imag_part))
          |> Nx.sqrt()

        magnitude_log =
          magnitude
          |> Nx.add(1.0)
          |> Nx.log()

        shifted = shift_dft(magnitude_log)

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

  defp shift_dft(tensor) do
    {height, width} = Nx.shape(tensor) |> then(&{elem(&1, 0), elem(&1, 1)})
    cx = div(width, 2)
    cy = div(height, 2)

    q0 = tensor[[0..(cy - 1), 0..(cx - 1)]]
    q1 = tensor[[0..(cy - 1), cx..(width - 1)]]
    q2 = tensor[[cy..(height - 1), 0..(cx - 1)]]
    q3 = tensor[[cy..(height - 1), cx..(width - 1)]]

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
