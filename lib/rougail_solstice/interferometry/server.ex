defmodule RougailSolstice.Interferometry.Server do
  @moduledoc """
  GenServer managing interferometry session state.
  Handles periodic preview capture, DFT preview generation, and analysis triggers.
  All image data is handled in-memory via ImageStore - no filesystem I/O.
  """

  use GenServer

  require Logger

  alias RougailSolstice.ImageStore
  alias RougailSolstice.Interferometry.CLI
  alias RougailSolstice.Interferometry.State
  alias RougailSolstice.Interferometry.WFT.Nx, as: WFT
  alias RougailSolstice.OpticalPieces
  alias RougailSolstice.Outline.Server, as: OutlineServer
  alias RougailSolstice.Robot.Server, as: RobotServer
  alias RougailSolstice.Sessions.Topics

  @pubsub RougailSolstice.PubSub
  @preview_interval 200

  defstruct [
    :interf_state,
    :session_id,
    :robot_server,
    :image_store,
    :optical_piece,
    :outline_server
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_state(GenServer.server()) :: State.t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @spec set_outline_circle(GenServer.server(), State.circle()) :: {:ok, State.t()}
  def set_outline_circle(server, circle) do
    GenServer.call(server, {:set_outline_circle, circle})
  end

  @spec set_center_filter_radius(GenServer.server(), pos_integer()) ::
          {:ok, State.t()} | {:error, term()}
  def set_center_filter_radius(server, radius) do
    GenServer.call(server, {:set_center_filter_radius, radius})
  end

  @spec load_optical_config(GenServer.server(), integer()) :: {:ok, State.t()}
  def load_optical_config(server, config_id) do
    GenServer.call(server, {:load_optical_config, config_id})
  end

  @spec set_optical_params(GenServer.server(), State.optical_params()) :: {:ok, State.t()}
  def set_optical_params(server, params) do
    GenServer.call(server, {:set_optical_params, params})
  end

  @spec start_liveview(GenServer.server()) :: {:ok, State.t()}
  def start_liveview(server) do
    GenServer.call(server, :start_liveview)
  end

  @spec stop_liveview(GenServer.server()) :: {:ok, State.t()}
  def stop_liveview(server) do
    GenServer.call(server, :stop_liveview)
  end

  @spec capture_full_shot(GenServer.server()) :: {:ok, State.t()} | {:error, term()}
  def capture_full_shot(server) do
    GenServer.call(server, :capture_full_shot, 30_000)
  end

  @spec reset(GenServer.server()) :: {:ok, State.t()}
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @spec analysis_readiness(GenServer.server()) :: State.readiness_check()
  def analysis_readiness(server) do
    GenServer.call(server, :analysis_readiness)
  end

  @spec subscribe(integer() | nil) :: :ok | {:error, term()}
  def subscribe(session_id \\ nil) do
    Phoenix.PubSub.subscribe(@pubsub, Topics.interferometry(session_id))
  end

  @spec topic(integer() | nil) :: String.t()
  def topic(session_id \\ nil), do: Topics.interferometry(session_id)

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id)
    robot_server = Keyword.get(opts, :robot_server, RobotServer)
    image_store = Keyword.get(opts, :image_store, ImageStore)
    optical_piece = Keyword.get(opts, :optical_piece)
    outline_server = Keyword.get(opts, :outline_server)

    interf_state = State.new()

    interf_state =
      if optical_piece do
        params = OpticalPieces.to_optical_params(optical_piece)
        State.set_optical_params(interf_state, params)
      else
        interf_state
      end

    {:ok,
     %__MODULE__{
       interf_state: interf_state,
       session_id: session_id,
       robot_server: robot_server,
       image_store: image_store,
       optical_piece: optical_piece,
       outline_server: outline_server
     }}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.interf_state, state}

  def handle_call(:analysis_readiness, _from, state) do
    {:reply, State.analysis_readiness(state.interf_state), state}
  end

  def handle_call({:set_outline_circle, circle}, _from, state) do
    new_interf = State.set_outline_circle(state.interf_state, circle)
    new_state = %{state | interf_state: new_interf}
    broadcast(new_state)
    {:reply, {:ok, new_interf}, new_state}
  end

  def handle_call({:set_center_filter_radius, radius}, _from, state) do
    case State.set_center_filter_radius(state.interf_state, radius) do
      {:ok, new_interf} ->
        new_state = %{state | interf_state: new_interf}
        broadcast(new_state)
        {:reply, {:ok, new_interf}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:load_optical_config, config_id}, _from, state) do
    optical_piece = OpticalPieces.get_optical_piece!(config_id)
    params = OpticalPieces.to_optical_params(optical_piece)

    new_interf = State.set_optical_params(state.interf_state, params)
    new_state = %{state | interf_state: new_interf, optical_piece: optical_piece}
    broadcast(new_state)
    {:reply, {:ok, new_interf}, new_state}
  end

  def handle_call({:set_optical_params, params}, _from, state) do
    new_interf = State.set_optical_params(state.interf_state, params)
    new_state = %{state | interf_state: new_interf}
    broadcast(new_state)
    {:reply, {:ok, new_interf}, new_state}
  end

  def handle_call(:start_liveview, _from, state) do
    Logger.info(
      "[InterfServer] start_liveview called, scheduling preview capture every #{@preview_interval}ms"
    )

    new_interf = State.start_liveview(state.interf_state)
    new_state = %{state | interf_state: new_interf}
    schedule_preview_capture()
    broadcast(new_state)
    {:reply, {:ok, new_interf}, new_state}
  end

  def handle_call(:stop_liveview, _from, state) do
    new_interf = State.stop_liveview(state.interf_state)
    new_state = %{state | interf_state: new_interf}
    broadcast(new_state)
    {:reply, {:ok, new_interf}, new_state}
  end

  def handle_call(:capture_full_shot, _from, state) do
    robot_state = RobotServer.get_state(state.robot_server)

    case robot_state.camera_adapter.capture() do
      {:ok, {:binary, binary, content_type}} ->
        case store_full_shot_in_session(binary, content_type, state) do
          {:ok, url, dims} ->
            new_interf = State.set_full_shot(state.interf_state, url, dims)
            new_state = %{state | interf_state: new_interf}
            broadcast(new_state)
            final_state = run_analysis_if_ready(new_state)
            {:reply, {:ok, final_state.interf_state}, final_state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:reset, _from, state) do
    new_interf = State.new()
    new_state = %{state | interf_state: new_interf}
    broadcast(new_state)
    {:reply, {:ok, new_interf}, new_state}
  end

  @impl true
  def handle_info(:capture_preview, state) do
    if state.interf_state.liveview_active do
      Logger.debug("[InterfServer] capture_preview tick - liveview active")
      new_state = capture_and_process_preview(state)
      schedule_preview_capture()
      {:noreply, new_state}
    else
      Logger.debug("[InterfServer] capture_preview tick - liveview not active, skipping")
      {:noreply, state}
    end
  end

  defp capture_and_process_preview(state) do
    robot_state = RobotServer.get_state(state.robot_server)

    case robot_state.camera_adapter.capture_preview() do
      {:ok, {:binary, binary, content_type}} ->
        case store_preview_in_session(binary, content_type, state) do
          {:ok, url, dims} ->
            push_frame_to_outline(state.outline_server, binary, dims)
            new_interf = State.set_preview_frame(state.interf_state, url, dims)
            new_state = %{state | interf_state: new_interf}
            broadcast(new_state)
            process_dft_preview(new_state)

          {:error, reason} ->
            Logger.warning("[InterfServer] Failed to store preview: #{inspect(reason)}")
            state
        end

      {:error, _} ->
        state
    end
  end

  defp push_frame_to_outline(nil, _binary, _dims), do: :ok

  defp push_frame_to_outline(outline_server, binary, dims) do
    OutlineServer.push_frame(outline_server, binary, dims)
  end

  defp store_preview_in_session(binary, content_type, state) do
    with {:ok, dims} <- get_binary_dimensions(binary) do
      preview_key = "preview_#{System.unique_integer([:positive])}"

      ImageStore.delete_prefix(state.image_store, "preview_")

      ImageStore.put(state.image_store, preview_key, binary,
        content_type: content_type,
        dimensions: dims
      )

      url = ImageStore.session_url(state.session_id, preview_key)
      {:ok, url, dims}
    end
  end

  defp store_full_shot_in_session(binary, content_type, state) do
    with {:ok, dims} <- get_binary_dimensions(binary) do
      shot_key = "full_shot_#{System.unique_integer([:positive])}"

      ImageStore.delete_prefix(state.image_store, "full_shot_")

      ImageStore.put(state.image_store, shot_key, binary,
        content_type: content_type,
        dimensions: dims
      )

      url = ImageStore.session_url(state.session_id, shot_key)
      {:ok, url, dims}
    end
  end

  defp get_binary_dimensions(binary) do
    case Evision.imdecode(binary, Evision.Constant.cv_IMREAD_UNCHANGED()) do
      %Evision.Mat{} = mat ->
        shape = Evision.Mat.shape(mat)

        case Tuple.to_list(shape) do
          [h, w | _] -> {:ok, {w, h}}
          _ -> {:error, :invalid_shape}
        end

      _ ->
        {:error, :decode_failed}
    end
  end

  defp process_dft_preview(state) do
    interf = state.interf_state

    if State.ready_for_dft_preview?(interf) do
      case process_dft_preview_binary(state) do
        {:ok, dft_url} ->
          new_interf = State.set_dft_preview(interf, dft_url)
          new_state = %{state | interf_state: new_interf}
          broadcast(new_state)
          new_state

        {:error, reason} ->
          Logger.warning("[InterfServer] DFT preview failed: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp process_dft_preview_binary(state) do
    interf = state.interf_state
    image_store = state.image_store

    with {:ok, image_binary} <- ImageStore.fetch_binary(image_store, interf.preview_frame_path),
         {:ok, {:binary, png_binary}} <-
           CLI.dft_preview(image_binary, interf.outline_circle, session_id: state.session_id) do
      key = "dft_preview_#{System.unique_integer([:positive])}"
      ImageStore.delete_prefix(image_store, "dft_preview_")
      ImageStore.put(image_store, key, png_binary, content_type: "image/png")
      {:ok, ImageStore.session_url(state.session_id, key)}
    end
  end

  defp run_analysis_if_ready(state) do
    interf = state.interf_state

    case State.analysis_readiness(interf) do
      :ready ->
        run_analysis(state)

      {:not_ready, missing} ->
        Logger.debug("[InterfServer] Not ready for analysis, missing: #{inspect(missing)}")
        state
    end
  end

  defp run_analysis(state) do
    interf = state.interf_state

    case State.scale_circle_to_full_shot(interf) do
      {:ok, scaled_circle} ->
        Logger.info("""
        [InterfServer] Running analysis:
          preview_dimensions: #{inspect(interf.preview_dimensions)}
          full_shot_dimensions: #{inspect(interf.full_shot_dimensions)}
          outline_circle (preview): cx=#{interf.outline_circle.cx}, cy=#{interf.outline_circle.cy}, r=#{interf.outline_circle.r}
          scaled_circle (full shot): cx=#{scaled_circle.cx}, cy=#{scaled_circle.cy}, r=#{scaled_circle.r}
        """)

        case run_cli_analysis(state.session_id, interf, scaled_circle, state.image_store) do
          {:ok, result} ->
            Logger.info("[InterfServer] Analysis succeeded, rms=#{result.rms_waves}")
            new_interf = State.set_analysis(interf, result)

            {new_interf, new_state} =
              render_wft_preview(%{state | interf_state: new_interf}, result)

            Logger.info(
              "[InterfServer] After render_wft_preview, wft_preview_path=#{inspect(new_interf.wft_preview_path)}"
            )

            broadcast(new_state)
            new_state

          {:error, reason} ->
            Logger.error("[InterfServer] Analysis failed: #{inspect(reason)}")
            state
        end

      {:error, reason} ->
        Logger.error("[InterfServer] Circle scaling failed: #{inspect(reason)}")
        state
    end
  end

  defp run_cli_analysis(session_id, interf, scaled_circle, image_store) do
    with {:ok, image_binary} <- ImageStore.fetch_binary(image_store, interf.full_shot_path) do
      CLI.analyze(
        image_binary,
        scaled_circle,
        interf.optical_params,
        center_filter: interf.center_filter_radius,
        session_id: session_id
      )
    end
  end

  defp render_wft_preview(state, result) do
    case result[:wft] do
      nil ->
        Logger.warning("[InterfServer] No WFT data from analysis")
        {state.interf_state, state}

      {:binary, wft_binary} ->
        render_wft_from_binary(state, wft_binary)
    end
  end

  defp render_wft_from_binary(state, wft_binary) do
    interf = state.interf_state
    Logger.info("[InterfServer] render_wft_preview using binary data")
    conic = interf.optical_params[:conic] || -1.0

    case WFT.parse(wft_binary, apply_null: true, conic: conic) do
      {:ok, wft} ->
        render_wft_to_store(state, wft)

      {:error, reason} ->
        Logger.warning("[InterfServer] WFT parse failed: #{inspect(reason)}")
        {interf, state}
    end
  end

  defp render_wft_to_store(state, wft) do
    interf = state.interf_state
    image_store = state.image_store

    case WFT.render_to_png(wft) do
      {:ok, png_binary, metadata} ->
        key = "wft_preview_#{System.unique_integer([:positive])}"
        ImageStore.delete_prefix(image_store, "wft_preview_")
        ImageStore.put(image_store, key, png_binary, content_type: "image/png")
        url = ImageStore.session_url(state.session_id, key)

        Logger.info("[InterfServer] WFT preview rendered: #{url}, stats: #{inspect(metadata)}")
        new_interf = State.set_wft_preview(interf, url)
        {new_interf, %{state | interf_state: new_interf}}

      {:error, reason} ->
        Logger.warning("[InterfServer] WFT render failed: #{inspect(reason)}")
        {interf, state}
    end
  end

  defp schedule_preview_capture do
    Process.send_after(self(), :capture_preview, @preview_interval)
  end

  defp broadcast(state) do
    topic = Topics.interferometry(state.session_id)

    Logger.debug(
      "[InterfServer] broadcasting to topic: #{topic}, session_id: #{inspect(state.session_id)}"
    )

    Phoenix.PubSub.broadcast(@pubsub, topic, {:interferometry_state_changed, state.interf_state})
  end
end
