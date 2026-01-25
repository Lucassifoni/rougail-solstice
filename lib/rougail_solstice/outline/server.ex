defmodule RougailSolstice.Outline.Server do
  @moduledoc """
  GenServer managing automatic outline detection.
  Receives frames via push_frame/2 and runs circle detection
  on a rolling window of preview frames.
  Supports session-scoped operation with optional session_id.
  When a circle is detected, invokes the on_circle_detected callback.
  """

  use GenServer

  require Logger

  alias RougailSolstice.ImageStore
  alias RougailSolstice.Outline.Detection
  alias RougailSolstice.Outline.State

  @process_interval_ms 200

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enable(GenServer.server()) :: :ok
  def enable(server) do
    GenServer.call(server, :enable)
  end

  @spec disable(GenServer.server()) :: :ok
  def disable(server) do
    GenServer.call(server, :disable)
  end

  @spec enabled?(GenServer.server()) :: boolean()
  def enabled?(server) do
    GenServer.call(server, :enabled?)
  end

  @spec get_state(GenServer.server()) :: State.t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @spec update_detection_params(GenServer.server(), map()) :: :ok
  def update_detection_params(server, params) when is_map(params) do
    GenServer.call(server, {:update_detection_params, params})
  end

  @spec update_state_params(GenServer.server(), map()) :: :ok
  def update_state_params(server, params) when is_map(params) do
    GenServer.call(server, {:update_state_params, params})
  end

  @spec push_frame(GenServer.server(), binary(), {integer(), integer()}) :: :ok
  def push_frame(server, binary, dimensions) do
    GenServer.cast(server, {:push_frame, binary, dimensions})
  end

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id)
    image_store = Keyword.get(opts, :image_store, ImageStore)
    on_circle_detected = Keyword.get(opts, :on_circle_detected, &noop/1)

    state = State.new(opts)

    {:ok,
     %{
       state: state,
       session_id: session_id,
       image_store: image_store,
       on_circle_detected: on_circle_detected,
       pending_detection: false,
       last_process_time: now() - @process_interval_ms
     }}
  end

  defp noop(_), do: :ok

  @impl true
  def handle_call(:enable, _from, server_state) do
    new_state = State.enable(server_state.state)
    Logger.info("[OutlineServer] Auto-outline enabled")
    {:reply, :ok, %{server_state | state: new_state}}
  end

  def handle_call(:disable, _from, server_state) do
    new_state = State.disable(server_state.state)
    Logger.info("[OutlineServer] Auto-outline disabled")
    {:reply, :ok, %{server_state | state: new_state}}
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
  def handle_cast({:push_frame, binary, dimensions}, server_state) do
    if server_state.state.enabled do
      frame = %{
        binary: binary,
        dimensions: dimensions,
        timestamp: System.monotonic_time(:millisecond)
      }

      new_state = State.push_frame(server_state.state, frame)
      frame_count = State.frame_count(new_state)
      max_frames = new_state.max_frames

      Logger.debug(
        "[OutlineServer] Received frame #{frame_count}/#{max_frames} (#{byte_size(binary)} bytes, #{inspect(dimensions)})"
      )

      server_state = %{server_state | state: new_state}
      server_state = maybe_schedule_detection(server_state)
      {:noreply, server_state}
    else
      {:noreply, server_state}
    end
  end

  @impl true
  def handle_info(:run_detection, server_state) do
    server_state = %{server_state | pending_detection: false}

    if State.ready_for_detection?(server_state.state) do
      Logger.info("[OutlineServer] Running detection pipeline...")

      result =
        run_detection_pipeline(
          server_state.state,
          server_state.session_id,
          server_state.image_store
        )

      handle_detection_result(result, server_state)
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

    server_state.on_circle_detected.(result.circle)
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

  defp run_detection_pipeline(state, session_id, image_store) do
    frames = State.get_frames(state)
    binaries = Enum.map(frames, & &1.binary)
    dims = hd(frames).dimensions

    Detection.run_detection(binaries, dims,
      threshold_percentile: state.threshold_percentile,
      min_confidence: state.min_confidence,
      detection_params: state.detection_params,
      session_id: session_id,
      image_store: image_store
    )
  end

  defp maybe_update(state, key, params) do
    case Map.get(params, key) do
      nil -> state
      value -> Map.put(state, key, value)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
