defmodule RougailSolstice.Interferometry.State do
  @moduledoc """
  Pure state management for interferometry session data.
  All functions are pure and return updated state structs.
  """

  @type circle :: %{cx: number(), cy: number(), r: number()}
  @type dimensions :: {non_neg_integer(), non_neg_integer()}
  @type optical_params :: %{
          diameter: number(),
          roc: number(),
          lambda: number(),
          conic: number(),
          obstruction: number()
        }

  @type t :: %__MODULE__{
          preview_frame_path: Path.t() | nil,
          preview_dimensions: dimensions() | nil,
          full_shot_path: Path.t() | nil,
          full_shot_dimensions: dimensions() | nil,
          dft_preview_path: Path.t() | nil,
          last_analysis: map() | nil,
          outline_circle: circle(),
          center_filter_radius: pos_integer(),
          optical_params: optical_params() | nil,
          liveview_active: boolean()
        }

  @enforce_keys []
  defstruct preview_frame_path: nil,
            preview_dimensions: nil,
            full_shot_path: nil,
            full_shot_dimensions: nil,
            dft_preview_path: nil,
            last_analysis: nil,
            outline_circle: %{cx: 0, cy: 0, r: 100},
            center_filter_radius: 10,
            optical_params: nil,
            liveview_active: false

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec set_outline_circle(t(), circle()) :: t()
  def set_outline_circle(%__MODULE__{} = state, %{cx: _, cy: _, r: _} = circle) do
    %{state | outline_circle: circle}
  end

  @spec set_center_filter_radius(t(), pos_integer()) ::
          {:ok, t()} | {:error, :invalid_radius}
  def set_center_filter_radius(%__MODULE__{} = state, radius)
      when is_integer(radius) and radius > 0 do
    {:ok, %{state | center_filter_radius: radius}}
  end

  def set_center_filter_radius(_, _), do: {:error, :invalid_radius}

  @spec set_optical_params(t(), optical_params()) :: t()
  def set_optical_params(%__MODULE__{} = state, params) when is_map(params) do
    %{state | optical_params: params}
  end

  @spec set_preview_frame(t(), Path.t(), dimensions()) :: t()
  def set_preview_frame(%__MODULE__{} = state, path, {w, h} = dims)
      when is_binary(path) and is_integer(w) and is_integer(h) do
    %{state | preview_frame_path: path, preview_dimensions: dims}
  end

  @spec set_full_shot(t(), Path.t(), dimensions()) :: t()
  def set_full_shot(%__MODULE__{} = state, path, {w, h} = dims)
      when is_binary(path) and is_integer(w) and is_integer(h) do
    %{state | full_shot_path: path, full_shot_dimensions: dims}
  end

  @spec set_dft_preview(t(), Path.t()) :: t()
  def set_dft_preview(%__MODULE__{} = state, path) when is_binary(path) do
    %{state | dft_preview_path: path}
  end

  @spec set_analysis(t(), map()) :: t()
  def set_analysis(%__MODULE__{} = state, analysis) when is_map(analysis) do
    %{state | last_analysis: analysis}
  end

  @spec clear_analysis(t()) :: t()
  def clear_analysis(%__MODULE__{} = state) do
    %{state | last_analysis: nil}
  end

  @spec start_liveview(t()) :: t()
  def start_liveview(%__MODULE__{} = state) do
    %{state | liveview_active: true}
  end

  @spec stop_liveview(t()) :: t()
  def stop_liveview(%__MODULE__{} = state) do
    %{state | liveview_active: false}
  end

  @spec ready_for_analysis?(t()) :: boolean()
  def ready_for_analysis?(%__MODULE__{} = state) do
    state.optical_params != nil and
      state.outline_circle.r > 0 and
      state.full_shot_path != nil and
      state.full_shot_dimensions != nil
  end

  @spec ready_for_dft_preview?(t()) :: boolean()
  def ready_for_dft_preview?(%__MODULE__{} = state) do
    state.preview_frame_path != nil and
      state.outline_circle.r > 0
  end

  @doc """
  Scales the outline circle from preview coordinates to full shot coordinates.
  Returns the scaled circle or error if dimensions are missing.
  """
  @spec scale_circle_to_full_shot(t()) :: {:ok, circle()} | {:error, :missing_dimensions}
  def scale_circle_to_full_shot(%__MODULE__{} = state) do
    with {preview_w, _preview_h} <- state.preview_dimensions,
         {full_w, _full_h} <- state.full_shot_dimensions do
      scale = full_w / preview_w
      circle = state.outline_circle

      scaled_circle = %{
        cx: circle.cx * scale,
        cy: circle.cy * scale,
        r: circle.r * scale
      }

      {:ok, scaled_circle}
    else
      nil -> {:error, :missing_dimensions}
    end
  end
end
