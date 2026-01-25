defmodule RougailSolstice.Outline.Detection do
  @moduledoc """
  Image processing for automatic outline detection using temporal variance analysis.
  Uses evision (OpenCV) for image processing and circle detection.
  """

  require Logger

  @type circle :: %{cx: number(), cy: number(), r: number()}
  @type detection_result :: %{
          circle: circle(),
          confidence: float(),
          method: :edge_ray_cast,
          # :hough_variance
          # | :canny_hough
          # | :otsu_contour
          # | :ray_peak_fit
          # | :radial_scan
          #  | :edge_ray_cast,
          image_dimensions: {pos_integer(), pos_integer()}
        }

  @type preview_result :: %{
          hit_points: [{number(), number()}],
          circle: circle() | nil,
          confidence: float(),
          frame_count: non_neg_integer(),
          image_dimensions: {pos_integer(), pos_integer()},
          params: map()
        }

  @debug_dir "priv/static/detection"

  @default_params %{
    edge_ray_count: 180,
    edge_threshold: 128,
    max_edge_dim: 1536,
    canny_low: 30,
    canny_high: 90,
    blur_kernel_size: 5,
    ransac_samples: 800,
    ransac_inlier_threshold_ratio: 0.05,
    ransac_refinement_iterations: 2,
    debug_save: false
  }

  @spec run_detection([binary()], {pos_integer(), pos_integer()}, keyword()) ::
          {:ok, detection_result()} | {:error, term()}
  def run_detection(binaries, {_expected_width, _expected_height}, opts \\ []) do
    min_confidence = Keyword.get(opts, :min_confidence, 0.5)
    params = Map.merge(@default_params, Keyword.get(opts, :detection_params, %{}))
    session_ctx = %{
      session_id: Keyword.get(opts, :session_id),
      image_store: Keyword.get(opts, :image_store, RougailSolstice.ImageStore)
    }

    Logger.info("[Detection] Starting with #{length(binaries)} frames")
    debug_save = params.debug_save

    with {:ok, mats} when mats != [] <- decode_images(binaries),
         {height, width} = get_mat_dimensions(hd(mats)),
         _ = Logger.info("[Detection] Actual image dimensions: #{width}x#{height}"),
         _ = debug_save && save_debug_image(hd(mats), "01_input_raw"),
         normalized_mats = normalize_histograms(mats),
         _ = debug_save && save_debug_image(hd(normalized_mats), "01_input_normalized"),
         {:ok, variance_map} <- compute_variance_map(normalized_mats) do
      if debug_save, do: save_variance_image(variance_map, "02_variance")
      variance_u8 = variance_to_u8(variance_map)
      results = run_all_strategies(variance_map, variance_u8, {width, height}, params, session_ctx)

      case select_best_result(results, min_confidence) do
        {:ok, result} ->
          result_with_dims = Map.put(result, :image_dimensions, {width, height})

          Logger.info(
            "[Detection] Best result: #{result.method} with confidence=#{Float.round(result.confidence, 3)}"
          )

          {:ok, result_with_dims}

        :no_detection ->
          Logger.info(
            "[Detection] All strategies failed to meet min_confidence=#{min_confidence}"
          )

          {:error, :no_detection}
      end
    else
      {:ok, []} ->
        Logger.info("[Detection] Failed: :no_frames")
        {:error, :no_frames}

      {:error, reason} = err ->
        Logger.info("[Detection] Failed: #{inspect(reason)}")
        err
    end
  end

  defp get_mat_dimensions(mat) do
    case Evision.Mat.shape(mat) do
      {h, w, _} -> {h, w}
      {h, w} -> {h, w}
    end
  end

  defp variance_to_u8(variance_map) do
    variance_map
    |> Nx.multiply(255.0)
    |> Nx.clip(0, 255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
  end

  defp run_all_strategies(_variance_map, variance_u8, dims, params, session_ctx) do
    [
      run_edge_ray_cast(variance_u8, dims, params, session_ctx)
    ]
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, r} -> r end)
  end

  defp select_best_result([], _min_confidence), do: :no_detection

  defp select_best_result(results, _min_confidence) do
    case Enum.find(results, &(&1.method == :edge_ray_cast)) do
      nil -> :no_detection
      edge_ray -> {:ok, edge_ray}
    end
  end

  defp scale_circle(%{cx: cx, cy: cy, r: r}, scale) do
    %{cx: cx * scale, cy: cy * scale, r: r * scale}
  end

  defp fit_circle_robust(points, _params) when length(points) < 3, do: :no_fit

  defp fit_circle_robust(points, params) do
    ransac_samples = params.ransac_samples
    ransac_iterations = params.ransac_refinement_iterations
    inlier_ratio = params.ransac_inlier_threshold_ratio

    circles = sample_circumcircles(points, ransac_samples)

    if length(circles) < 10 do
      Logger.info("[Detection] Robust fit: insufficient valid circumcircles (#{length(circles)})")
      :no_fit
    else
      {consensus_circle, inlier_points} = find_consensus_circle(circles, points, inlier_ratio)

      {final_circle, final_inliers} =
        Enum.reduce(1..ransac_iterations, {consensus_circle, inlier_points}, fn _, acc ->
          refine_iteration(points, acc, inlier_ratio)
        end)

      fit_error = compute_fit_error(final_inliers, final_circle)

      Logger.info(
        "[Detection] Robust fit: #{length(final_inliers)}/#{length(points)} inliers, " <>
          "error=#{Float.round(fit_error, 2)}"
      )

      {:ok, final_circle, fit_error}
    end
  end

  defp refine_iteration(points, {circle, _inliers}, inlier_ratio) do
    new_inliers = filter_inliers(points, circle, inlier_ratio)
    maybe_refine_circle(circle, new_inliers)
  end

  defp maybe_refine_circle(circle, inliers) when length(inliers) < 3, do: {circle, inliers}

  defp maybe_refine_circle(circle, inliers) do
    case refine_circle_from_inliers(inliers, circle.r) do
      {:ok, new_circle} -> {new_circle, inliers}
      :no_fit -> {circle, inliers}
    end
  end

  defp sample_circumcircles(points, n_samples) do
    points_vec = List.to_tuple(points)
    n_points = tuple_size(points_vec)

    if n_points < 3 do
      []
    else
      1..n_samples
      |> Enum.map(fn _ -> sample_three_distinct(points_vec, n_points) end)
      |> Enum.map(&fit_circumcircle/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, c} -> c end)
    end
  end

  defp sample_three_distinct(points_vec, n) do
    i = :rand.uniform(n) - 1
    j = sample_different(n, [i])
    k = sample_different(n, [i, j])
    {elem(points_vec, i), elem(points_vec, j), elem(points_vec, k)}
  end

  defp sample_different(n, exclude) do
    candidate = :rand.uniform(n) - 1

    if candidate in exclude do
      sample_different(n, exclude)
    else
      candidate
    end
  end

  defp fit_circumcircle({{x1, y1}, {x2, y2}, {x3, y3}}) do
    a = x1 * (y2 - y3) - y1 * (x2 - x3) + x2 * y3 - x3 * y2

    if abs(a) < 1.0e-10 do
      :collinear
    else
      sq1 = x1 * x1 + y1 * y1
      sq2 = x2 * x2 + y2 * y2
      sq3 = x3 * x3 + y3 * y3

      cx = (sq1 * (y2 - y3) + sq2 * (y3 - y1) + sq3 * (y1 - y2)) / (2 * a)
      cy = (sq1 * (x3 - x2) + sq2 * (x1 - x3) + sq3 * (x2 - x1)) / (2 * a)
      r = :math.sqrt((cx - x1) * (cx - x1) + (cy - y1) * (cy - y1))

      if r > 0 and cx > 0 and cy > 0 do
        {:ok, %{cx: cx, cy: cy, r: r}}
      else
        :invalid
      end
    end
  end

  defp find_consensus_circle(circles, points, inlier_ratio) do
    median_r = circles |> Enum.map(& &1.r) |> Enum.sort() |> Enum.at(div(length(circles), 2))
    {cx, cy} = find_center_for_radius(points, median_r)
    consensus = %{cx: cx, cy: cy, r: median_r}
    inliers = filter_inliers(points, consensus, inlier_ratio)
    {consensus, inliers}
  end

  defp find_center_for_radius(points, r) do
    xs = Enum.map(points, fn {x, _} -> x end)
    ys = Enum.map(points, fn {_, y} -> y end)
    init_cx = Enum.sum(xs) / length(xs)
    init_cy = Enum.sum(ys) / length(ys)
    refine_center(points, r, init_cx, init_cy, 20)
  end

  defp refine_center(_points, _r, cx, cy, 0), do: {cx, cy}

  defp refine_center(points, r, cx, cy, iterations) do
    adjustments =
      Enum.map(points, fn {x, y} ->
        dx = x - cx
        dy = y - cy
        dist = :math.sqrt(dx * dx + dy * dy)

        if dist < 1.0e-6 do
          {0.0, 0.0, 0.0}
        else
          error = dist - r
          weight = 1.0 / (abs(error) + 1.0)
          nx = dx / dist
          ny = dy / dist
          {error * nx * weight, error * ny * weight, weight}
        end
      end)

    total_weight = Enum.sum(Enum.map(adjustments, fn {_, _, w} -> w end))

    if total_weight < 1.0e-6 do
      {cx, cy}
    else
      adj_x = Enum.sum(Enum.map(adjustments, fn {ax, _, _} -> ax end)) / total_weight
      adj_y = Enum.sum(Enum.map(adjustments, fn {_, ay, _} -> ay end)) / total_weight
      refine_center(points, r, cx + adj_x, cy + adj_y, iterations - 1)
    end
  end

  defp refine_circle_from_inliers(points, _r) when length(points) < 3, do: :no_fit

  defp refine_circle_from_inliers(points, r) do
    {cx, cy} = find_center_for_radius(points, r)
    {:ok, %{cx: cx, cy: cy, r: r}}
  end

  defp filter_inliers(points, %{cx: cx, cy: cy, r: r}, inlier_ratio) do
    threshold = r * inlier_ratio

    Enum.filter(points, fn {x, y} ->
      dist = :math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy))
      abs(dist - r) <= threshold
    end)
  end

  defp compute_fit_error(points, %{cx: cx, cy: cy, r: r}) do
    if points == [] do
      1.0
    else
      points
      |> Enum.map(fn {x, y} ->
        dist = :math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy))
        abs(dist - r)
      end)
      |> Enum.sum()
      |> Kernel./(length(points))
    end
  end

  defp run_edge_ray_cast(variance_u8, {width, height}, params, session_ctx) do
    Logger.info("[Detection] Strategy: Edge Ray Cast")

    edge_ray_count = params.edge_ray_count
    edge_threshold = params.edge_threshold
    max_edge_dim = params.max_edge_dim
    canny_low = params.canny_low
    canny_high = params.canny_high
    blur_kernel_size = params.blur_kernel_size
    debug_save = params.debug_save

    {small, scale} = downscale_for_edge_cast(variance_u8, {width, height}, max_edge_dim)
    {sh, sw} = get_mat_dimensions(small)

    blur_size = {blur_kernel_size, blur_kernel_size}
    blurred = Evision.gaussianBlur(small, blur_size, 0)
    edges = Evision.canny(blurred, canny_low, canny_high)
    debug_save && save_debug_image(edges, "03_edge_ray_cast_edges")

    edges_binary = Evision.imencode(".png", edges)
    key = "edges_preview"
    image_store = session_ctx.image_store
    RougailSolstice.ImageStore.put(image_store, key, edges_binary, content_type: "image/png")
    url = RougailSolstice.ImageStore.session_url(session_ctx.session_id, key)
    broadcast_preview_edges(url, session_ctx.session_id)

    edges_tensor = Evision.Mat.to_nx(edges, EXLA.Backend)

    center_x = sw / 2
    center_y = sh / 2

    hit_points =
      cast_rays_from_outside(
        edges_tensor,
        center_x,
        center_y,
        {sw, sh},
        edge_ray_count,
        edge_threshold
      )

    if length(hit_points) < 10 do
      Logger.info("[Detection] Edge Ray Cast: insufficient hit points (#{length(hit_points)})")
      :no_detection
    else
      case fit_circle_robust(hit_points, params) do
        {:ok, small_circle, fit_error} ->
          circle = scale_circle(small_circle, scale)

          confidence =
            calculate_edge_ray_confidence(hit_points, small_circle, fit_error, edge_ray_count)

          Logger.info(
            "[Detection] Edge Ray Cast: confidence=#{Float.round(confidence, 3)}, fit_error=#{Float.round(fit_error, 3)}"
          )

          debug_save && save_edge_ray_debug(edges, hit_points, small_circle, "03_edge_ray_cast")
          {:ok, %{circle: circle, confidence: confidence, method: :edge_ray_cast}}

        :no_fit ->
          Logger.info("[Detection] Edge Ray Cast: circle fitting failed")
          :no_detection
      end
    end
  rescue
    e ->
      Logger.info("[Detection] Edge Ray Cast failed: #{inspect(e)}")
      :no_detection
  end

  defp broadcast_preview_edges(path, session_id) do
    alias RougailSolstice.Sessions.Topics

    Phoenix.PubSub.broadcast(
      RougailSolstice.PubSub,
      Topics.outline_preview(session_id),
      {:preview_edges, path}
    )
  end

  defp downscale_for_edge_cast(mat, {width, height}, max_edge_dim) do
    max_dim = max(width, height)

    if max_dim > max_edge_dim do
      scale = max_dim / max_edge_dim
      new_w = round(width / scale)
      new_h = round(height / scale)
      small = Evision.resize(mat, {new_w, new_h})
      {small, scale}
    else
      {mat, 1.0}
    end
  end

  defp cast_rays_from_outside(
         edges_tensor,
         center_x,
         center_y,
         {width, height},
         edge_ray_count,
         edge_threshold
       ) do
    max_dist = :math.sqrt(width * width + height * height) / 2 + 10
    num_samples = round(max_dist)

    angles =
      Nx.iota({edge_ray_count}, type: :f32)
      |> Nx.multiply(2 * :math.pi() / edge_ray_count)

    distances =
      Nx.iota({num_samples}, type: :f32)
      |> Nx.multiply(-1)
      |> Nx.add(max_dist)

    cos_angles = Nx.cos(angles)
    sin_angles = Nx.sin(angles)

    x_coords = Nx.add(center_x, Nx.outer(cos_angles, distances))
    y_coords = Nx.add(center_y, Nx.outer(sin_angles, distances))

    x_rounded = Nx.round(x_coords)
    y_rounded = Nx.round(y_coords)

    valid_mask =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(x_rounded, 0), Nx.less(x_rounded, width)),
        Nx.logical_and(Nx.greater_equal(y_rounded, 0), Nx.less(y_rounded, height))
      )

    x_indices = x_rounded |> Nx.clip(0, width - 1) |> Nx.as_type(:s32)
    y_indices = y_rounded |> Nx.clip(0, height - 1) |> Nx.as_type(:s32)

    flat_y = Nx.reshape(y_indices, {:auto})
    flat_x = Nx.reshape(x_indices, {:auto})
    indices = Nx.stack([flat_y, flat_x], axis: 1)

    flat_values = Nx.gather(edges_tensor, indices)
    values = Nx.reshape(flat_values, {edge_ray_count, num_samples})
    values = Nx.select(valid_mask, values, 0)

    edge_mask = Nx.greater(values, edge_threshold)

    position_weights =
      Nx.iota({num_samples}, type: :f32)
      |> Nx.multiply(-1)
      |> Nx.add(num_samples)

    weighted = Nx.multiply(Nx.as_type(edge_mask, :f32), position_weights)

    first_hit_indices = Nx.argmax(weighted, axis: 1)
    has_hit = Nx.greater(Nx.reduce_max(weighted, axes: [1]), 0)

    ray_indices = Nx.iota({edge_ray_count}, type: :s32)
    gather_indices = Nx.stack([ray_indices, Nx.as_type(first_hit_indices, :s32)], axis: 1)

    hit_x = Nx.gather(x_rounded, gather_indices)
    hit_y = Nx.gather(y_rounded, gather_indices)

    hit_x_list = Nx.to_flat_list(hit_x)
    hit_y_list = Nx.to_flat_list(hit_y)
    has_hit_list = Nx.to_flat_list(has_hit)

    Enum.zip([hit_x_list, hit_y_list, has_hit_list])
    |> Enum.filter(fn {_x, _y, hit} -> hit == 1 end)
    |> Enum.map(fn {x, y, _} -> {round(x), round(y)} end)
  end

  defp calculate_edge_ray_confidence(points, %{cx: cx, cy: cy, r: r}, fit_error, edge_ray_count) do
    radii =
      Enum.map(points, fn {x, y} ->
        :math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy))
      end)

    mean_radius = Enum.sum(radii) / length(radii)

    variance =
      Enum.sum(Enum.map(radii, fn ri -> (ri - mean_radius) * (ri - mean_radius) end)) /
        length(radii)

    std_dev = :math.sqrt(variance)

    relative_error = if mean_radius > 0, do: std_dev / mean_radius, else: 1.0
    normalized_fit_error = if r > 0, do: fit_error / r, else: 1.0

    coverage = length(points) / edge_ray_count

    error_score = max(0.0, 1.0 - relative_error * 3)
    fit_score = max(0.0, 1.0 - normalized_fit_error * 5)
    coverage_score = min(coverage * 1.5, 1.0)

    confidence = error_score * 0.4 + fit_score * 0.3 + coverage_score * 0.3
    min(max(confidence, 0.0), 1.0)
  end

  defp save_edge_ray_debug(edges, hit_points, %{cx: cx, cy: cy, r: r}, name) do
    color_mat = Evision.cvtColor(edges, Evision.Constant.cv_COLOR_GRAY2BGR())

    Enum.each(hit_points, fn {x, y} ->
      Evision.circle(color_mat, {round(x), round(y)}, 3, {255, 0, 0}, thickness: -1)
    end)

    Evision.circle(color_mat, {round(cx), round(cy)}, round(r), {0, 255, 0}, thickness: 2)
    Evision.circle(color_mat, {round(cx), round(cy)}, 3, {0, 0, 255}, thickness: -1)

    save_debug_image(color_mat, name)
  rescue
    e -> Logger.info("[Detection] Failed to save edge ray debug: #{inspect(e)}")
  end

  defp normalize_histograms(mats) do
    clahe = Evision.createCLAHE(clipLimit: 2.0, tileGridSize: {8, 8})
    Enum.map(mats, fn mat -> Evision.CLAHE.apply(clahe, mat) end)
  end

  @spec decode_images([binary()]) :: {:ok, [Evision.Mat.t()]} | {:error, term()}
  defp decode_images(binaries) do
    mats =
      Enum.reduce_while(binaries, [], fn binary, acc ->
        case decode_grayscale(binary) do
          {:ok, mat} -> {:cont, [mat | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case mats do
      {:error, reason} -> {:error, reason}
      list when is_list(list) -> {:ok, Enum.reverse(list)}
    end
  end

  @spec decode_grayscale(binary()) :: {:ok, Evision.Mat.t()} | {:error, term()}
  defp decode_grayscale(binary) do
    case Evision.imdecode(binary, Evision.Constant.cv_IMREAD_GRAYSCALE()) do
      %Evision.Mat{} = mat -> {:ok, mat}
      {:error, reason} -> {:error, {:decode_failed, reason}}
      _ -> {:error, :decode_failed}
    end
  end

  @spec compute_variance_map([Evision.Mat.t()]) :: {:ok, Evision.Mat.t()} | {:error, term()}
  defp compute_variance_map([]) do
    {:error, :no_frames}
  end

  defp compute_variance_map(mats) do
    tensors =
      Enum.map(mats, fn mat ->
        mat
        |> Evision.Mat.to_nx(EXLA.Backend)
        |> Nx.as_type(:f32)
      end)

    n = length(tensors)
    half = div(n, 2)
    first_half = Enum.take(tensors, half)
    second_half = Enum.drop(tensors, half) |> Enum.take(half)

    differences =
      Enum.zip(first_half, second_half)
      |> Enum.map(fn {a, b} -> Nx.subtract(b, a) end)

    stacked = Nx.stack(differences, axis: 0)
    mean = Nx.mean(stacked, axes: [0])
    diff_squared = Nx.pow(Nx.subtract(stacked, mean), 2)
    variance = Nx.mean(diff_squared, axes: [0])

    min_var = Nx.reduce_min(variance)
    max_var = Nx.reduce_max(variance)
    range = Nx.subtract(max_var, min_var)

    stretched =
      if Nx.to_number(range) > 1.0e-6 do
        variance |> Nx.subtract(min_var) |> Nx.divide(range)
      else
        Nx.broadcast(0.0, Nx.shape(variance))
      end

    {:ok, stretched}
  rescue
    e -> {:error, {:variance_computation_failed, e}}
  end

  defp save_debug_image(mat, name) do
    path = Path.join(@debug_dir, "#{name}.png")
    Evision.imwrite(path, mat)
    Logger.info("[Detection] Saved #{path}")
  rescue
    e -> Logger.info("[Detection] Failed to save #{name}: #{inspect(e)}")
  end

  defp save_variance_image(variance_tensor, name) do
    scaled =
      variance_tensor
      |> Nx.multiply(255.0)
      |> Nx.clip(0, 255)
      |> Nx.as_type(:u8)

    mat = Evision.Mat.from_nx(scaled)
    save_debug_image(mat, name)
  rescue
    e -> Logger.info("[Detection] Failed to save variance image: #{inspect(e)}")
  end
end
