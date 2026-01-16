defmodule RougailSolstice.Outline.State do
  @moduledoc """
  Pure state management for outline detection.
  Maintains a rolling window of preview frames for variance-based circle detection.
  """

  @type frame :: %{
          binary: binary(),
          dimensions: {pos_integer(), pos_integer()},
          timestamp: integer()
        }

  @type detection_result :: %{
          circle: %{cx: number(), cy: number(), r: number()},
          confidence: float(),
          method: :hough | :contour_fit,
          detected_at: integer()
        }

  @type detection_params :: %{
          edge_ray_count: pos_integer(),
          edge_threshold: non_neg_integer(),
          max_edge_dim: pos_integer(),
          canny_low: non_neg_integer(),
          canny_high: non_neg_integer(),
          blur_kernel_size: pos_integer(),
          ransac_samples: pos_integer(),
          ransac_inlier_threshold_ratio: float(),
          ransac_refinement_iterations: non_neg_integer(),
          debug_save: boolean()
        }

  @type t :: %__MODULE__{
          enabled: boolean(),
          frames: :queue.queue(frame()),
          max_frames: pos_integer(),
          threshold_percentile: float(),
          min_confidence: float(),
          last_detection: detection_result() | nil,
          consecutive_failures: non_neg_integer(),
          detection_params: detection_params()
        }

  @default_detection_params %{
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

  defstruct enabled: false,
            frames: :queue.new(),
            max_frames: 50,
            threshold_percentile: 0.8,
            min_confidence: 0.7,
            last_detection: nil,
            consecutive_failures: 0,
            detection_params: @default_detection_params

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    detection_params =
      Map.merge(@default_detection_params, Keyword.get(opts, :detection_params, %{}))

    %__MODULE__{
      max_frames: Keyword.get(opts, :max_frames, 50),
      threshold_percentile: Keyword.get(opts, :threshold_percentile, 0.8),
      min_confidence: Keyword.get(opts, :min_confidence, 0.7),
      detection_params: detection_params
    }
  end

  @spec default_detection_params() :: detection_params()
  def default_detection_params, do: @default_detection_params

  @spec update_detection_params(t(), map()) :: t()
  def update_detection_params(%__MODULE__{} = state, params) when is_map(params) do
    new_params = Map.merge(state.detection_params, params)
    %{state | detection_params: new_params}
  end

  @spec enable(t()) :: t()
  def enable(%__MODULE__{} = state) do
    %{state | enabled: true}
  end

  @spec disable(t()) :: t()
  def disable(%__MODULE__{} = state) do
    %{state | enabled: false, frames: :queue.new(), consecutive_failures: 0}
  end

  @spec push_frame(t(), frame()) :: t()
  def push_frame(%__MODULE__{} = state, frame) do
    queue = :queue.in(frame, state.frames)

    queue =
      if :queue.len(queue) > state.max_frames do
        {_, q} = :queue.out(queue)
        q
      else
        queue
      end

    %{state | frames: queue}
  end

  @spec frame_count(t()) :: non_neg_integer()
  def frame_count(%__MODULE__{} = state) do
    :queue.len(state.frames)
  end

  @spec ready_for_detection?(t()) :: boolean()
  def ready_for_detection?(%__MODULE__{} = state) do
    state.enabled and :queue.len(state.frames) >= state.max_frames
  end

  @spec get_frames(t()) :: [frame()]
  def get_frames(%__MODULE__{} = state) do
    :queue.to_list(state.frames)
  end

  @spec set_detection(t(), detection_result()) :: t()
  def set_detection(%__MODULE__{} = state, result) do
    %{state | last_detection: result, consecutive_failures: 0}
  end

  @spec record_failure(t()) :: t()
  def record_failure(%__MODULE__{} = state) do
    %{state | consecutive_failures: state.consecutive_failures + 1}
  end

  @spec should_suppress_logging?(t()) :: boolean()
  def should_suppress_logging?(%__MODULE__{} = state) do
    state.consecutive_failures > 5
  end

  @spec clear_frames(t()) :: t()
  def clear_frames(%__MODULE__{} = state) do
    %{state | frames: :queue.new()}
  end
end
