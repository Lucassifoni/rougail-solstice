defmodule RougailSolstice.Interferometry.Sidecar.Worker do
  @moduledoc """
  GenServer that manages a persistent DFTFringe sidecar process via Elixir Port.

  Each worker maintains a single sidecar process and processes requests synchronously.
  The worker buffers port output until a complete response (terminated by "---") is received.
  """

  use GenServer
  require Logger

  alias RougailSolstice.Interferometry.Sidecar.Protocol

  @type role :: :analyze

  defstruct [:port, :role, :buffer, :caller, :mode, :docker_image]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_config(GenServer.server(), map()) :: :ok | {:error, term()}
  def send_config(worker, config) do
    GenServer.call(worker, {:config, config}, 10_000)
  end

  @spec send_analyze(GenServer.server(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def send_analyze(worker, image_binary, circle) do
    GenServer.call(worker, {:analyze, image_binary, circle}, 60_000)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(worker) do
    GenServer.call(worker, :quit, 5_000)
  end

  @impl true
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    mode = Keyword.get(opts, :mode, cli_mode())
    docker_image = Keyword.get(opts, :docker_image, docker_image())

    state = %__MODULE__{
      port: nil,
      role: role,
      buffer: "",
      caller: nil,
      mode: mode,
      docker_image: docker_image
    }

    case start_port(state) do
      {:ok, port} ->
        Logger.info("[Sidecar.Worker] Started #{role} worker (mode: #{mode})")
        {:ok, %{state | port: port}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:config, config}, from, state) do
    message = Protocol.encode_config(config)
    send_and_await(message, from, state)
  end

  def handle_call({:analyze, image_binary, circle}, from, state) do
    message = Protocol.encode_analyze(image_binary, circle)
    send_and_await(message, from, state)
  end

  def handle_call(:quit, from, state) do
    message = Protocol.encode_quit()
    Port.command(state.port, IO.iodata_to_binary(message))
    {:reply, :ok, %{state | caller: from}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    case Protocol.find_terminator(buffer) do
      {:complete, response, rest} ->
        result = Protocol.decode_response(response)

        if state.caller do
          GenServer.reply(state.caller, result)
        end

        {:noreply, %{state | buffer: rest, caller: nil}}

      :incomplete ->
        {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[Sidecar.Worker] Port exited with status #{status}, restarting...")

    if state.caller do
      GenServer.reply(state.caller, {:error, {:port_exit, status}})
    end

    case start_port(state) do
      {:ok, new_port} ->
        {:noreply, %{state | port: new_port, buffer: "", caller: nil}}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    Logger.warning("[Sidecar.Worker] Port closed unexpectedly, restarting...")

    if state.caller do
      GenServer.reply(state.caller, {:error, :port_closed})
    end

    case start_port(state) do
      {:ok, new_port} ->
        {:noreply, %{state | port: new_port, buffer: "", caller: nil}}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[Sidecar.Worker] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      Port.close(state.port)
    end

    :ok
  end

  defp send_and_await(message, from, state) do
    Port.command(state.port, IO.iodata_to_binary(message))
    {:noreply, %{state | caller: from}}
  end

  defp start_port(state) do
    case state.mode do
      :native -> start_native_port()
      :docker -> start_docker_port(state.docker_image)
    end
  end

  defp start_native_port do
    executable = System.find_executable("dftfringe-cli")

    if executable do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["--sidecar"]
        ])

      {:ok, port}
    else
      {:error, :executable_not_found}
    end
  end

  defp start_docker_port(image) do
    docker = System.find_executable("docker")

    if docker do
      port =
        Port.open({:spawn_executable, docker}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["run", "-i", "--rm", image, "--sidecar"]
        ])

      {:ok, port}
    else
      {:error, :docker_not_found}
    end
  end

  defp cli_mode do
    Application.get_env(:rougail_solstice, RougailSolstice.Interferometry.CLI, [])
    |> Keyword.get(:mode, :native)
  end

  defp docker_image do
    Application.get_env(:rougail_solstice, RougailSolstice.Interferometry.CLI, [])
    |> Keyword.get(:docker_image, "dftfringe-cli:latest")
  end
end
