defmodule RougailSolstice.Interferometry.Server do
  @moduledoc """
  GenServer managing interferometry session state.
  Handles periodic preview capture, DFT preview generation, and analysis triggers.
  """

  use GenServer

  require Logger

  alias RougailSolstice.Interferometry.CLI
  alias RougailSolstice.Interferometry.State
  alias RougailSolstice.Interferometry.WFT
  alias RougailSolstice.Robot.Server, as: RobotServer

  @pubsub RougailSolstice.PubSub
  @topic "interferometry:state"
  @preview_interval 1000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_state(GenServer.server()) :: State.t()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @spec set_outline_circle(GenServer.server(), State.circle()) :: {:ok, State.t()}
  def set_outline_circle(server \\ __MODULE__, circle) do
    GenServer.call(server, {:set_outline_circle, circle})
  end

  @spec set_center_filter_radius(GenServer.server(), pos_integer()) ::
          {:ok, State.t()} | {:error, term()}
  def set_center_filter_radius(server \\ __MODULE__, radius) do
    GenServer.call(server, {:set_center_filter_radius, radius})
  end

  @spec load_optical_config(GenServer.server(), integer()) :: {:ok, State.t()}
  def load_optical_config(server \\ __MODULE__, config_id) do
    GenServer.call(server, {:load_optical_config, config_id})
  end

  @spec set_optical_params(GenServer.server(), State.optical_params()) :: {:ok, State.t()}
  def set_optical_params(server \\ __MODULE__, params) do
    GenServer.call(server, {:set_optical_params, params})
  end

  @spec start_liveview(GenServer.server()) :: {:ok, State.t()}
  def start_liveview(server \\ __MODULE__) do
    GenServer.call(server, :start_liveview)
  end

  @spec stop_liveview(GenServer.server()) :: {:ok, State.t()}
  def stop_liveview(server \\ __MODULE__) do
    GenServer.call(server, :stop_liveview)
  end

  @spec capture_full_shot(GenServer.server()) :: {:ok, State.t()} | {:error, term()}
  def capture_full_shot(server \\ __MODULE__) do
    GenServer.call(server, :capture_full_shot, 30_000)
  end

  @spec reset(GenServer.server()) :: {:ok, State.t()}
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(_opts) do
    {:ok, State.new()}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_call({:set_outline_circle, circle}, _from, state) do
    new_state = State.set_outline_circle(state, circle)
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call({:set_center_filter_radius, radius}, _from, state) do
    case State.set_center_filter_radius(state, radius) do
      {:ok, new_state} ->
        broadcast(new_state)
        {:reply, {:ok, new_state}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:load_optical_config, config_id}, _from, state) do
    config = RougailSolstice.Interferometry.get_config!(config_id)

    params = %{
      diameter: config.diameter,
      roc: config.roc,
      lambda: config.lambda,
      conic: config.conic,
      obstruction: config.obstruction
    }

    new_state = State.set_optical_params(state, params)
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call({:set_optical_params, params}, _from, state) do
    new_state = State.set_optical_params(state, params)
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call(:start_liveview, _from, state) do
    Logger.info(
      "[InterfServer] start_liveview called, scheduling preview capture every #{@preview_interval}ms"
    )

    new_state = State.start_liveview(state)
    schedule_preview_capture()
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call(:stop_liveview, _from, state) do
    new_state = State.stop_liveview(state)
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  def handle_call(:capture_full_shot, _from, state) do
    robot_state = RobotServer.get_state()

    case robot_state.camera_adapter.capture() do
      {:ok, image_path} ->
        case get_image_dimensions(image_path) do
          {:ok, dims} ->
            new_state = State.set_full_shot(state, image_path, dims)
            broadcast(new_state)
            final_state = run_analysis_if_ready(new_state)
            {:reply, {:ok, final_state}, final_state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:reset, _from, _state) do
    new_state = State.new()
    broadcast(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  @impl true
  def handle_info(:capture_preview, state) do
    if state.liveview_active do
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
    robot_state = RobotServer.get_state()

    case robot_state.camera_adapter.capture_preview() do
      {:ok, preview_path} ->
        case get_image_dimensions(preview_path) do
          {:ok, dims} ->
            state = State.set_preview_frame(state, preview_path, dims)
            broadcast(state)
            process_dft_preview(state)

          {:error, _} ->
            state
        end

      {:error, _} ->
        state
    end
  end

  defp process_dft_preview(state) do
    if State.ready_for_dft_preview?(state) do
      with {:ok, input_path} <- resolve_preview_to_file(state.preview_frame_path),
           dft_output =
             Path.join(System.tmp_dir!(), "dft_preview_#{System.unique_integer([:positive])}.png"),
           {:ok, _dft_path} <- CLI.dft_preview(input_path, state.outline_circle, dft_output),
           {:ok, dft_url} <- store_dft_preview(dft_output) do
        new_state = State.set_dft_preview(state, dft_url)
        broadcast(new_state)
        new_state
      else
        {:error, reason} ->
          Logger.warning("[InterfServer] DFT preview failed: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp resolve_preview_to_file("/images/" <> key) do
    case RougailSolstice.ImageStore.get(key) do
      %{binary: binary} ->
        temp_path =
          Path.join(System.tmp_dir!(), "preview_input_#{System.unique_integer([:positive])}.jpg")

        File.write!(temp_path, binary)
        {:ok, temp_path}

      nil ->
        {:error, :preview_not_found}
    end
  end

  defp resolve_preview_to_file(path) when is_binary(path) do
    if File.exists?(path), do: {:ok, path}, else: {:error, :file_not_found}
  end

  defp store_dft_preview(file_path) do
    case File.read(file_path) do
      {:ok, binary} ->
        key = "dft_preview_#{System.unique_integer([:positive])}"
        RougailSolstice.ImageStore.delete_prefix("dft_preview_")
        RougailSolstice.ImageStore.put(key, binary, content_type: "image/png")
        File.rm(file_path)
        {:ok, RougailSolstice.ImageStore.url(key)}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp run_analysis_if_ready(state) do
    ready = State.ready_for_analysis?(state)
    Logger.info("[InterfServer] run_analysis_if_ready: ready=#{ready}")

    with true <- ready,
         {:ok, scaled_circle} <- State.scale_circle_to_full_shot(state) do
      Logger.info("""
      [InterfServer] Running analysis:
        preview_dimensions: #{inspect(state.preview_dimensions)}
        full_shot_dimensions: #{inspect(state.full_shot_dimensions)}
        outline_circle (preview): cx=#{state.outline_circle.cx}, cy=#{state.outline_circle.cy}, r=#{state.outline_circle.r}
        scaled_circle (full shot): cx=#{scaled_circle.cx}, cy=#{scaled_circle.cy}, r=#{scaled_circle.r}
      """)

      case run_cli_analysis(state, scaled_circle) do
        {:ok, result} ->
          Logger.info("[InterfServer] Analysis succeeded, rms=#{result.rms_waves}")
          new_state = State.set_analysis(state, result)
          new_state = render_wft_preview(new_state, result)

          Logger.info(
            "[InterfServer] After render_wft_preview, wft_preview_path=#{inspect(new_state.wft_preview_path)}"
          )

          broadcast(new_state)
          new_state

        {:error, reason} ->
          Logger.error("[InterfServer] Analysis failed: #{inspect(reason)}")
          state
      end
    else
      false ->
        Logger.debug("[InterfServer] Not ready for analysis")
        state

      {:error, reason} ->
        Logger.error("[InterfServer] Circle scaling failed: #{inspect(reason)}")
        state
    end
  end

  defp run_cli_analysis(state, scaled_circle) do
    CLI.analyze(
      state.full_shot_path,
      scaled_circle,
      state.optical_params,
      center_filter: state.center_filter_radius
    )
  end

  defp render_wft_preview(state, result) do
    wft_path = result[:wft_path]

    if is_nil(wft_path) or not File.exists?(wft_path) do
      Logger.warning("[InterfServer] No WFT file from analysis: #{inspect(wft_path)}")
      state
    else
      Logger.info("[InterfServer] render_wft_preview using: #{wft_path}")

      conic = state.optical_params[:conic] || -1.0
      Logger.info("[InterfServer] Rendering WFT with conic=#{conic}")

      case WFT.parse_file(wft_path, apply_null: true, conic: conic) do
        {:ok, wft} ->
          case WFT.render_to_png(wft) do
            {:ok, png_binary, metadata} ->
              key = "wft_preview_#{System.unique_integer([:positive])}"
              RougailSolstice.ImageStore.delete_prefix("wft_preview_")
              RougailSolstice.ImageStore.put(key, png_binary, content_type: "image/png")
              url = RougailSolstice.ImageStore.url(key)

              Logger.info(
                "[InterfServer] WFT preview rendered: #{url}, stats: #{inspect(metadata)}"
              )

              State.set_wft_preview(state, url)

            {:error, reason} ->
              Logger.warning("[InterfServer] WFT render failed: #{inspect(reason)}")
              state
          end

        {:error, reason} ->
          Logger.warning("[InterfServer] WFT parse failed: #{inspect(reason)}")
          state
      end
    end
  end

  defp get_image_dimensions("/images/" <> key) do
    case RougailSolstice.ImageStore.get(key) do
      %{dimensions: {_, _} = dims} -> {:ok, dims}
      %{dimensions: nil} -> {:error, :no_dimensions}
      nil -> {:error, :not_found}
    end
  end

  defp get_image_dimensions(path) do
    case System.cmd("identify", ["-format", "%wx%h", path], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(String.trim(output), "x") do
          [w, h] ->
            {:ok, {String.to_integer(w), String.to_integer(h)}}

          _ ->
            {:error, :invalid_dimensions}
        end

      {_, _} ->
        {:error, :identify_failed}
    end
  end

  defp schedule_preview_capture do
    Process.send_after(self(), :capture_preview, @preview_interval)
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:interferometry_state_changed, state})
  end
end
