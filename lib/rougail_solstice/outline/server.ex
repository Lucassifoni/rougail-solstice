defmodule RougailSolstice.Outline.Server do
  @moduledoc """
  GenServer managing automatic outline detection.
  Subscribes to interferometry state changes and runs circle detection
  on a rolling window of preview frames.
  """

  use GenServer

  require Logger

  alias RougailSolstice.ImageStore
  alias RougailSolstice.Interferometry.Server, as: InterfServer
  alias RougailSolstice.Outline.Detection
  alias RougailSolstice.Outline.State

  @pubsub RougailSolstice.PubSub
  @interferometry_topic "interferometry:state"
  @process_interval_ms 200

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enable(GenServer.server()) :: :ok
  def enable(server \\ __MODULE__) do
    GenServer.call(server, :enable)
  end

  @spec disable(GenServer.server()) :: :ok
  def disable(server \\ __MODULE__) do
    GenServer.call(server, :disable)
  end

  @spec enabled?(GenServer.server()) :: boolean()
  def enabled?(server \\ __MODULE__) do
    GenServer.call(server, :enabled?)
  end

  @spec get_state(GenServer.server()) :: State.t()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @spec update_detection_params(GenServer.server(), map()) :: :ok
  def update_detection_params(server \\ __MODULE__, params) when is_map(params) do
    GenServer.call(server, {:update_detection_params, params})
  end

  @spec update_state_params(GenServer.server(), map()) :: :ok
  def update_state_params(server \\ __MODULE__, params) when is_map(params) do
    GenServer.call(server, {:update_state_params, params})
  end

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(@pubsub, @interferometry_topic)

    state = State.new(opts)

    {:ok,
     %{
       state: state,
       pending_detection: false,
       last_process_time: now() - @process_interval_ms,
       last_preview_path: nil
     }}
  end

  @impl true
  def handle_call(:enable, _from, server_state) do
    new_state = State.enable(server_state.state)
    Logger.info("[OutlineServer] Auto-outline enabled")

    server_state = %{server_state | state: new_state}
    server_state = maybe_capture_current_frame(server_state)
    {:reply, :ok, server_state}
  end

  def handle_call(:disable, _from, server_state) do
    new_state = State.disable(server_state.state)
    Logger.info("[OutlineServer] Auto-outline disabled")
    {:reply, :ok, %{server_state | state: new_state, last_preview_path: nil}}
  end

  def handle_call(:enabled?, _from, server_state) do
    {:reply, server_state.state.enabled, server_state}
  end

  def handle_call(:get_state, _from, server_state) do
    {:reply, server_state.state, server_state}
  end

  def handle_call({:update_detection_params, params}, _from, server_state) do
    new_state = State.update_detection_params(server_state.state, params)
    Logger.info("[OutlineServer] Updated detection params: #{inspect(params)}")
    {:reply, :ok, %{server_state | state: new_state}}
  end

  def handle_call({:update_state_params, params}, _from, server_state) do
    new_state =
      server_state.state
      |> maybe_update(:max_frames, params)
      |> maybe_update(:threshold_percentile, params)
      |> maybe_update(:min_confidence, params)

    Logger.info("[OutlineServer] Updated state params: #{inspect(params)}")
    {:reply, :ok, %{server_state | state: new_state}}
  end

  @impl true
  def handle_info({:interferometry_state_changed, interf_state}, server_state) do
    if server_state.state.enabled and interf_state.liveview_active do
      server_state = maybe_capture_frame(server_state, interf_state)
      server_state = maybe_schedule_detection(server_state)
      {:noreply, server_state}
    else
      {:noreply, server_state}
    end
  end

  def handle_info(:run_detection, server_state) do
    server_state = %{server_state | pending_detection: false}

    if State.ready_for_detection?(server_state.state) do
      Logger.info("[OutlineServer] Running detection pipeline...")
      handle_detection_result(run_detection_pipeline(server_state.state), server_state)
    else
      {:noreply, server_state}
    end
  end

  def handle_info(_msg, server_state) do
    {:noreply, server_state}
  end

  defp handle_detection_result({:ok, result}, server_state) do
    Logger.info(
      "[OutlineServer] Circle detected: cx=#{round(result.circle.cx)}, cy=#{round(result.circle.cy)}, r=#{round(result.circle.r)} (confidence: #{Float.round(result.confidence, 2)}, method: #{result.method})"
    )

    update_interferometry_circle(result.circle)
    new_state = State.set_detection(server_state.state, Map.put(result, :detected_at, now()))
    {:noreply, %{server_state | state: new_state, last_process_time: now()}}
  end

  defp handle_detection_result({:error, reason}, server_state) do
    unless State.should_suppress_logging?(server_state.state) do
      Logger.debug("[OutlineServer] Detection failed: #{inspect(reason)}")
    end

    new_state = State.record_failure(server_state.state)
    {:noreply, %{server_state | state: new_state}}
  end

  defp maybe_capture_frame(server_state, interf_state) do
    preview_path = interf_state.preview_frame_path

    if preview_path && preview_path != server_state.last_preview_path do
      case fetch_frame_binary(preview_path, interf_state.preview_dimensions) do
        {:ok, binary, dims} ->
          frame = %{
            binary: binary,
            dimensions: dims,
            timestamp: System.monotonic_time(:millisecond)
          }

          new_state = State.push_frame(server_state.state, frame)
          frame_count = State.frame_count(new_state)
          max_frames = new_state.max_frames

          Logger.debug(
            "[OutlineServer] Captured frame #{frame_count}/#{max_frames} (#{byte_size(binary)} bytes, #{inspect(dims)})"
          )

          %{server_state | state: new_state, last_preview_path: preview_path}

        {:error, reason} ->
          Logger.debug("[OutlineServer] Failed to fetch frame: #{inspect(reason)}")
          server_state
      end
    else
      server_state
    end
  end

  defp fetch_frame_binary("/images/" <> key, dims) do
    case ImageStore.get(key) do
      %{binary: binary} when binary != nil ->
        actual_dims = dims || {640, 480}
        {:ok, binary, actual_dims}

      _ ->
        {:error, :not_found}
    end
  end

  defp fetch_frame_binary(path, dims) when is_binary(path) do
    case File.read(path) do
      {:ok, binary} ->
        actual_dims = dims || get_file_dimensions(path) || {640, 480}
        {:ok, binary, actual_dims}

      error ->
        error
    end
  end

  defp fetch_frame_binary(_, _), do: {:error, :invalid_path}

  defp get_file_dimensions(path) do
    case System.cmd("identify", ["-format", "%wx%h", path], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(String.trim(output), "x") do
          [w, h] -> {String.to_integer(w), String.to_integer(h)}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_schedule_detection(server_state) do
    now = now()
    elapsed = now - server_state.last_process_time
    ready = State.ready_for_detection?(server_state.state)
    frame_count = State.frame_count(server_state.state)

    Logger.debug(
      "[OutlineServer] Schedule check: frames=#{frame_count}, ready=#{ready}, pending=#{server_state.pending_detection}, elapsed=#{elapsed}ms"
    )

    cond do
      server_state.pending_detection ->
        Logger.debug("[OutlineServer] Skipping: detection already pending")
        server_state

      elapsed < @process_interval_ms ->
        Logger.debug(
          "[OutlineServer] Skipping: too soon (#{elapsed}ms < #{@process_interval_ms}ms)"
        )

        server_state

      ready ->
        Logger.info("[OutlineServer] Scheduling detection...")
        Process.send_after(self(), :run_detection, 0)
        %{server_state | pending_detection: true}

      true ->
        Logger.debug("[OutlineServer] Skipping: not ready")
        server_state
    end
  end

  defp run_detection_pipeline(state) do
    frames = State.get_frames(state)
    binaries = Enum.map(frames, & &1.binary)
    dims = hd(frames).dimensions

    Detection.run_detection(binaries, dims,
      threshold_percentile: state.threshold_percentile,
      min_confidence: state.min_confidence,
      detection_params: state.detection_params
    )
  end

  defp maybe_update(state, key, params) do
    case Map.get(params, key) do
      nil -> state
      value -> Map.put(state, key, value)
    end
  end

  defp update_interferometry_circle(circle) do
    InterfServer.set_outline_circle(circle)
  end

  defp maybe_capture_current_frame(server_state) do
    interf_state = InterfServer.get_state()

    if interf_state.liveview_active do
      Logger.debug("[OutlineServer] Liveview active, capturing current frame immediately")
      maybe_capture_frame(server_state, interf_state)
    else
      server_state
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
