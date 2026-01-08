require Logger
Logger.configure(level: :debug)

defmodule DebugDetection do
  def run do
    samples_dir = Path.join([File.cwd!(), "priv", "static", "samples"])

    files =
      samples_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".JPG"))
      |> Enum.sort()
      |> Enum.map(&Path.join(samples_dir, &1))

    IO.puts("Found #{length(files)} sample images:")
    Enum.each(files, &IO.puts("  - #{&1}"))

    binaries = Enum.map(files, &File.read!/1)
    IO.puts("\nLoaded #{length(binaries)} binaries, sizes: #{inspect(Enum.map(binaries, &byte_size/1))}")

    IO.puts("\n=== Step 1: Decode images ===")
    mats = decode_all(binaries)
    IO.puts("Decoded #{length(mats)} images")

    first_mat = hd(mats)
    {h, w} = Evision.Mat.shape(first_mat) |> then(fn {h, w} -> {h, w} end)
    IO.puts("Image dimensions: #{w}x#{h}")

    IO.puts("\n=== Step 2: Compute variance map ===")
    variance_tensor = compute_variance(mats)
    IO.puts("Variance tensor shape: #{inspect(Nx.shape(variance_tensor))}")
    IO.puts("Variance tensor type: #{inspect(Nx.type(variance_tensor))}")

    var_min = Nx.reduce_min(variance_tensor) |> Nx.to_number()
    var_max = Nx.reduce_max(variance_tensor) |> Nx.to_number()
    var_mean = Nx.mean(variance_tensor) |> Nx.to_number()
    IO.puts("Variance stats: min=#{Float.round(var_min, 6)}, max=#{Float.round(var_max, 6)}, mean=#{Float.round(var_mean, 6)}")

    percentiles = compute_percentiles(variance_tensor, [50, 75, 90, 95, 99])
    IO.puts("Variance percentiles: #{inspect(percentiles)}")

    IO.puts("\n=== Step 3: Test different thresholds ===")
    thresholds = [0.001, 0.005, 0.01, 0.02, 0.05, 0.1, 0.15]
    Enum.each(thresholds, fn thresh ->
      mask = threshold_to_mask(variance_tensor, thresh)
      non_zero = Evision.countNonZero(mask)
      total = w * h
      pct = Float.round(non_zero / total * 100, 2)
      IO.puts("  threshold=#{thresh}: #{non_zero}/#{total} pixels (#{pct}%)")
    end)

    IO.puts("\n=== Step 4: Select optimal threshold and apply morphology ===")
    optimal_thresh = 0.005
    mask = threshold_to_mask(variance_tensor, optimal_thresh)
    IO.puts("Using threshold: #{optimal_thresh}")
    IO.puts("Initial mask non-zero: #{Evision.countNonZero(mask)}")

    cleaned_mask = apply_morphology(mask)
    IO.puts("After morphology non-zero: #{Evision.countNonZero(cleaned_mask)}")

    Evision.imwrite("/tmp/debug_variance_mask_raw.png", mask)
    Evision.imwrite("/tmp/debug_variance_mask_cleaned.png", cleaned_mask)
    IO.puts("Saved masks to /tmp/debug_variance_mask_*.png")

    variance_visual =
      variance_tensor
      |> Nx.multiply(255 * 10)
      |> Nx.clip(0, 255)
      |> Nx.as_type(:u8)
      |> Evision.Mat.from_nx()
    Evision.imwrite("/tmp/debug_variance_map.png", variance_visual)
    IO.puts("Saved variance visualization to /tmp/debug_variance_map.png")

    IO.puts("\n=== Step 5: Attempt circle detection ===")
    detect_circle_debug(cleaned_mask, {w, h})

    IO.puts("\n=== Step 6: Test contour detection directly ===")
    detect_contour_debug(cleaned_mask)

    IO.puts("\n=== Step 7: Full pipeline test ===")
    result = RougailSolstice.Outline.Detection.run_detection(
      binaries,
      {w, h},
      variance_threshold: optimal_thresh,
      min_confidence: 0.3
    )
    IO.puts("Full pipeline result: #{inspect(result)}")
  end

  defp decode_all(binaries) do
    Enum.map(binaries, fn binary ->
      Evision.imdecode(binary, Evision.Constant.cv_IMREAD_GRAYSCALE())
    end)
  end

  defp compute_variance(mats) do
    tensors =
      Enum.map(mats, fn mat ->
        mat
        |> Evision.Mat.to_nx(Nx.BinaryBackend)
        |> Nx.as_type(:f32)
      end)

    stacked = Nx.stack(tensors, axis: 0)
    mean = Nx.mean(stacked, axes: [0])
    diff_squared = Nx.pow(Nx.subtract(stacked, mean), 2)
    variance = Nx.mean(diff_squared, axes: [0])
    max_variance = 255.0 * 255.0
    Nx.divide(variance, max_variance)
  end

  defp compute_percentiles(tensor, percentiles) do
    flat = Nx.flatten(tensor) |> Nx.to_flat_list()
    sorted = Enum.sort(flat)
    n = length(sorted)

    Enum.map(percentiles, fn p ->
      idx = round(p / 100 * (n - 1))
      val = Enum.at(sorted, idx)
      {p, Float.round(val, 6)}
    end)
  end

  defp threshold_to_mask(variance_tensor, threshold) do
    variance_tensor
    |> Nx.greater(threshold)
    |> Nx.select(Nx.tensor(255, type: :u8), Nx.tensor(0, type: :u8))
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
  end

  defp apply_morphology(mask) do
    kernel = Evision.getStructuringElement(Evision.Constant.cv_MORPH_ELLIPSE(), {5, 5})
    closed = Evision.morphologyEx(mask, Evision.Constant.cv_MORPH_CLOSE(), kernel)
    Evision.morphologyEx(closed, Evision.Constant.cv_MORPH_OPEN(), kernel)
  end

  defp detect_circle_debug(mask, {width, height}) do
    blurred = Evision.gaussianBlur(mask, {5, 5}, 0)
    min_dim = min(width, height)

    configs = [
      %{dp: 1.0, min_dist: div(min_dim, 4), p1: 100, p2: 30, min_r: div(min_dim, 10), max_r: div(min_dim, 2)},
      %{dp: 1.0, min_dist: div(min_dim, 8), p1: 50, p2: 20, min_r: div(min_dim, 8), max_r: div(min_dim, 2)},
      %{dp: 1.5, min_dist: div(min_dim, 4), p1: 50, p2: 15, min_r: div(min_dim, 6), max_r: div(min_dim, 2)},
      %{dp: 2.0, min_dist: div(min_dim, 4), p1: 30, p2: 10, min_r: div(min_dim, 8), max_r: div(min_dim, 2)},
    ]

    Enum.each(configs, fn cfg ->
      circles = Evision.houghCircles(
        blurred,
        Evision.Constant.cv_HOUGH_GRADIENT(),
        cfg.dp,
        cfg.min_dist,
        param1: cfg.p1,
        param2: cfg.p2,
        minRadius: cfg.min_r,
        maxRadius: cfg.max_r
      )

      case circles do
        %Evision.Mat{shape: {1, n, 3}} = mat when n > 0 ->
          tensor = Evision.Mat.to_nx(mat)
          first_circle = tensor |> Nx.squeeze(axes: [0]) |> Nx.slice([0, 0], [1, 3]) |> Nx.to_flat_list()
          IO.puts("  Config #{inspect(cfg)}: found #{n} circles, first: #{inspect(first_circle)}")
        _ ->
          IO.puts("  Config #{inspect(cfg)}: no circles found")
      end
    end)
  end

  defp detect_contour_debug(mask) do
    {contours, _hierarchy} = Evision.findContours(
      mask,
      Evision.Constant.cv_RETR_EXTERNAL(),
      Evision.Constant.cv_CHAIN_APPROX_SIMPLE()
    )

    IO.puts("Found #{length(contours)} contours")

    if length(contours) > 0 do
      contours
      |> Enum.map(fn c -> {c, Evision.contourArea(c)} end)
      |> Enum.sort_by(fn {_, area} -> -area end)
      |> Enum.take(5)
      |> Enum.with_index(1)
      |> Enum.each(fn {{contour, area}, idx} ->
        {{cx, cy}, radius} = Evision.minEnclosingCircle(contour)
        perimeter = Evision.arcLength(contour, true)
        circularity = if perimeter > 0, do: 4 * :math.pi() * area / (perimeter * perimeter), else: 0
        IO.puts("  Contour #{idx}: area=#{round(area)}, enclosing circle: center=(#{Float.round(cx, 1)}, #{Float.round(cy, 1)}), r=#{Float.round(radius, 1)}, circularity=#{Float.round(circularity, 3)}")
      end)
    end
  end
end

DebugDetection.run()
