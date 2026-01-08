defmodule RougailSolstice.Interferometry.Server do
  @moduledoc """
  GenServer managing interferometry session state.
  Handles periodic preview capture, DFT preview generation, and analysis triggers.
  """

  use GenServer

  alias RougailSolstice.Interferometry.CLI
  alias RougailSolstice.Interferometry.State
  alias RougailSolstice.Robot.Server, as: RobotServer

  @pubsub RougailSolstice.PubSub
  @topic "interferometry:state"
  @preview_interval 500

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
        maybe_rerun_analysis(new_state)
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
      new_state = capture_and_process_preview(state)
      schedule_preview_capture()
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:run_analysis, state) do
    new_state = run_analysis_if_ready(state)
    {:noreply, new_state}
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
      dft_output =
        Path.join(System.tmp_dir!(), "dft_preview_#{System.unique_integer([:positive])}.png")

      case CLI.dft_preview(state.preview_frame_path, state.outline_circle, dft_output) do
        {:ok, dft_path} ->
          new_state = State.set_dft_preview(state, dft_path)
          broadcast(new_state)
          new_state

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  defp maybe_rerun_analysis(state) do
    if State.ready_for_analysis?(state) do
      send(self(), :run_analysis)
    end
  end

  defp run_analysis_if_ready(state) do
    with true <- State.ready_for_analysis?(state),
         {:ok, scaled_circle} <- State.scale_circle_to_full_shot(state),
         {:ok, result} <- run_cli_analysis(state, scaled_circle) do
      new_state = State.set_analysis(state, result)
      broadcast(new_state)
      new_state
    else
      _ -> state
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
