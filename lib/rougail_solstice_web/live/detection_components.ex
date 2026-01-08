defmodule RougailSolsticeWeb.DetectionComponents do
  @moduledoc """
  LiveView components for outline detection settings.
  """

  use Phoenix.Component

  attr :outline_state, :map, required: true

  def detection_settings(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Detection Settings</h2>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <.state_params_form outline_state={@outline_state} />
        <.detection_params_form outline_state={@outline_state} />
      </div>
    </div>
    """
  end

  attr :outline_state, :map, required: true

  defp state_params_form(assigns) do
    ~H"""
    <div>
      <h3 class="text-sm font-medium text-gray-700 mb-3">Frame Collection</h3>
      <form phx-change="update_outline_state_params" class="space-y-3">
        <div>
          <label class="block text-xs text-gray-500">Max Frames</label>
          <input
            type="number"
            name="max_frames"
            value={@outline_state.max_frames}
            min="10"
            max="200"
            step="5"
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
          <p class="text-xs text-gray-400 mt-1">Frames to collect before detection (10-200)</p>
        </div>

        <div>
          <label class="block text-xs text-gray-500">Min Confidence</label>
          <input
            type="number"
            name="min_confidence"
            value={@outline_state.min_confidence}
            min="0.1"
            max="1.0"
            step="0.05"
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
          <p class="text-xs text-gray-400 mt-1">Minimum confidence threshold (0.1-1.0)</p>
        </div>

        <div>
          <label class="block text-xs text-gray-500">Threshold Percentile</label>
          <input
            type="number"
            name="threshold_percentile"
            value={@outline_state.threshold_percentile}
            min="0.1"
            max="1.0"
            step="0.05"
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
          <p class="text-xs text-gray-400 mt-1">Variance threshold percentile (0.1-1.0)</p>
        </div>
      </form>
    </div>
    """
  end

  attr :outline_state, :map, required: true

  defp detection_params_form(assigns) do
    params = assigns.outline_state.detection_params
    assigns = assign(assigns, :params, params)

    ~H"""
    <div>
      <h3 class="text-sm font-medium text-gray-700 mb-3">Edge Detection</h3>
      <form phx-change="update_detection_params" class="space-y-3">
        <div class="grid grid-cols-2 gap-2">
          <div>
            <label class="block text-xs text-gray-500">Ray Count</label>
            <input
              type="number"
              name="edge_ray_count"
              value={@params.edge_ray_count}
              min="36"
              max="360"
              step="18"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>

          <div>
            <label class="block text-xs text-gray-500">Edge Threshold</label>
            <input
              type="number"
              name="edge_threshold"
              value={@params.edge_threshold}
              min="10"
              max="255"
              step="10"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
        </div>

        <div class="grid grid-cols-2 gap-2">
          <div>
            <label class="block text-xs text-gray-500">Canny Low</label>
            <input
              type="number"
              name="canny_low"
              value={@params.canny_low}
              min="5"
              max="150"
              step="5"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>

          <div>
            <label class="block text-xs text-gray-500">Canny High</label>
            <input
              type="number"
              name="canny_high"
              value={@params.canny_high}
              min="30"
              max="300"
              step="10"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
        </div>

        <div class="grid grid-cols-2 gap-2">
          <div>
            <label class="block text-xs text-gray-500">Blur Kernel</label>
            <select
              name="blur_kernel_size"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            >
              <option value="3" selected={@params.blur_kernel_size == 3}>3</option>
              <option value="5" selected={@params.blur_kernel_size == 5}>5</option>
              <option value="7" selected={@params.blur_kernel_size == 7}>7</option>
              <option value="9" selected={@params.blur_kernel_size == 9}>9</option>
            </select>
          </div>

          <div>
            <label class="block text-xs text-gray-500">Max Edge Dim</label>
            <input
              type="number"
              name="max_edge_dim"
              value={@params.max_edge_dim}
              min="512"
              max="4096"
              step="256"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
        </div>

        <h3 class="text-sm font-medium text-gray-700 mt-4 mb-2">RANSAC Fitting</h3>

        <div class="grid grid-cols-2 gap-2">
          <div>
            <label class="block text-xs text-gray-500">Samples</label>
            <input
              type="number"
              name="ransac_samples"
              value={@params.ransac_samples}
              min="100"
              max="2000"
              step="100"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>

          <div>
            <label class="block text-xs text-gray-500">Iterations</label>
            <input
              type="number"
              name="ransac_refinement_iterations"
              value={@params.ransac_refinement_iterations}
              min="0"
              max="10"
              step="1"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
        </div>

        <div>
          <label class="block text-xs text-gray-500">Inlier Threshold Ratio</label>
          <input
            type="number"
            name="ransac_inlier_threshold_ratio"
            value={@params.ransac_inlier_threshold_ratio}
            min="0.01"
            max="0.5"
            step="0.01"
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
          <p class="text-xs text-gray-400 mt-1">Fraction of radius for inlier distance</p>
        </div>

        <div class="flex items-center gap-2 mt-2">
          <input
            type="checkbox"
            name="debug_save"
            id="debug_save"
            value="true"
            checked={@params.debug_save}
            class="rounded border-gray-300"
          />
          <label for="debug_save" class="text-xs text-gray-500">Save debug images</label>
        </div>
      </form>
    </div>
    """
  end
end
