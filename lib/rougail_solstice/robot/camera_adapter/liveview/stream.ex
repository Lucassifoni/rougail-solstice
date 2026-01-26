defmodule RougailSolstice.Robot.CameraAdapter.Liveview.Stream do
  @moduledoc """
  GenServer managing continuous liveview streaming from Canon cameras via gphoto2.

  Opens a port to `gphoto2 --capture-movie --stdout` and parses the raw JPEG stream.
  Delivers complete frames via a callback function.

  Handles port failures with restart attempts using exponential backoff.
  """

  use GenServer

  require Logger

  alias RougailSolstice.Robot.CameraAdapter.Liveview.JpegParser

  @max_restart_attempts 3
  @initial_backoff_ms 1000

  defstruct [
    :port,
    :camera_port,
    :parser_state,
    :latest_frame,
    :status,
    :restart_attempts,
    :port_spawner
  ]

  @type status :: :running | :stopped | :failed
  @type t :: %__MODULE__{
          port: port() | nil,
          camera_port: String.t() | nil,
          parser_state: JpegParser.state(),
          latest_frame: binary() | nil,
          status: status(),
          restart_attempts: non_neg_integer(),
          port_spawner: (list() -> port()) | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @spec status(GenServer.server()) :: status()
  def status(server) do
    GenServer.call(server, :status)
  end

  @spec get_latest_frame(GenServer.server()) :: {:ok, binary()} | {:error, :no_frame}
  def get_latest_frame(server) do
    GenServer.call(server, :get_latest_frame)
  end

  @impl true
  def init(opts) do
    camera_port = Keyword.get(opts, :camera_port)
    port_spawner = Keyword.get(opts, :port_spawner, &default_port_spawner/1)

    state = %__MODULE__{
      port: nil,
      camera_port: camera_port,
      parser_state: JpegParser.new(),
      latest_frame: nil,
      status: :stopped,
      restart_attempts: 0,
      port_spawner: port_spawner
    }

    {:ok, start_capture(state)}
  end

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:get_latest_frame, _from, state) do
    case state.latest_frame do
      nil -> {:reply, {:error, :no_frame}, state}
      frame -> {:reply, {:ok, frame}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {frames, new_parser_state} = JpegParser.push(state.parser_state, data)

    latest_frame =
      case frames do
        [] -> state.latest_frame
        _ -> List.last(frames)
      end

    {:noreply,
     %{state | parser_state: new_parser_state, latest_frame: latest_frame, restart_attempts: 0}}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    Logger.warning("[Liveview.Stream] Port exited with code #{exit_code}")
    handle_port_exit(state)
  end

  def handle_info({:DOWN, _ref, :port, port, reason}, %{port: port} = state) do
    Logger.warning("[Liveview.Stream] Port down: #{inspect(reason)}")
    handle_port_exit(state)
  end

  def handle_info(:restart_capture, state) do
    {:noreply, start_capture(state)}
  end

  def handle_info(msg, state) do
    Logger.debug("[Liveview.Stream] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp start_capture(state) do
    if state.restart_attempts >= @max_restart_attempts do
      Logger.error("[Liveview.Stream] Max restart attempts reached, giving up")
      %{state | status: :failed}
    else
      do_start_capture(state)
    end
  end

  defp do_start_capture(state) do
    if state.restart_attempts > 0 do
      Logger.info("[Liveview.Stream] Waiting 500ms before restart to let camera reset")
      Process.sleep(500)
    end

    args = build_args(state.camera_port)

    try do
      port = state.port_spawner.(args)
      Port.monitor(port)
      Logger.info("[Liveview.Stream] Started capture with args: #{inspect(args)}")
      %{state | port: port, status: :running, parser_state: JpegParser.new()}
    rescue
      e ->
        Logger.error("[Liveview.Stream] Failed to start port: #{inspect(e)}")
        new_state = %{state | restart_attempts: state.restart_attempts + 1}
        schedule_restart(new_state)
    end
  end

  defp build_args(nil), do: ["gphoto2", "--capture-movie", "--stdout"]

  defp build_args(camera_port),
    do: ["gphoto2", "--port", camera_port, "--capture-movie", "--stdout"]

  defp default_port_spawner(args) do
    [cmd | cmd_args] = args

    Port.open({:spawn_executable, System.find_executable(cmd)}, [
      :binary,
      :exit_status,
      {:args, cmd_args}
    ])
  end

  defp handle_port_exit(state) do
    close_port(state.port)
    new_state = %{state | port: nil, restart_attempts: state.restart_attempts + 1}

    if new_state.restart_attempts >= @max_restart_attempts do
      Logger.error("[Liveview.Stream] Max restart attempts reached, giving up")
      {:noreply, %{new_state | status: :failed}}
    else
      {:noreply, schedule_restart(new_state)}
    end
  end

  defp schedule_restart(state) do
    backoff = calculate_backoff(state.restart_attempts)

    Logger.info(
      "[Liveview.Stream] Scheduling restart in #{backoff}ms (attempt #{state.restart_attempts}/#{@max_restart_attempts})"
    )

    Process.send_after(self(), :restart_capture, backoff)
    %{state | status: :stopped}
  end

  defp calculate_backoff(attempts) do
    (@initial_backoff_ms * :math.pow(2, attempts - 1)) |> trunc() |> max(@initial_backoff_ms)
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Logger.info("[Liveview.Stream] Killing gphoto2 process (OS PID: #{os_pid})")
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)
        Process.sleep(1000)

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
