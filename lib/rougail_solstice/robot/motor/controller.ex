defmodule RougailSolstice.Robot.Motor.Controller do
  @moduledoc """
  GenServer managing serial communication with the Arduino motor controller.
  When port is nil, operates in virtual mode (logs commands, no hardware).
  """

  use GenServer

  require Logger

  alias RougailSolstice.Robot.Motor.{Command, Protocol}

  @default_baud_rate 115_200

  defstruct [:uart_pid, :port, :baud_rate, :virtual]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    init_opts = Keyword.take(opts, [:port, :baud_rate])
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @spec send_command(GenServer.server(), Command.t()) :: :ok
  def send_command(server, %Command{} = cmd) do
    GenServer.call(server, {:send_command, cmd})
  end

  @spec stop_all(GenServer.server()) :: :ok
  def stop_all(server) do
    GenServer.call(server, :stop_all)
  end

  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server) do
    GenServer.call(server, :connected?)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port)
    baud_rate = Keyword.get(opts, :baud_rate, @default_baud_rate)

    if port do
      {:ok, uart_pid} = Circuits.UART.start_link()

      case Circuits.UART.open(uart_pid, port, speed: baud_rate, active: false) do
        :ok ->
          Logger.info("[MotorController] Connected to #{port} at #{baud_rate} baud")
          {:ok, %__MODULE__{uart_pid: uart_pid, port: port, baud_rate: baud_rate, virtual: false}}

        {:error, reason} ->
          Logger.warning(
            "[MotorController] Failed to open #{port}: #{inspect(reason)}, falling back to virtual mode"
          )

          Circuits.UART.stop(uart_pid)
          {:ok, %__MODULE__{port: port, baud_rate: baud_rate, virtual: true}}
      end
    else
      Logger.info("[MotorController] No port configured, running in virtual mode")
      {:ok, %__MODULE__{port: nil, baud_rate: baud_rate, virtual: true}}
    end
  end

  @impl true
  def handle_call({:send_command, cmd}, _from, state) do
    frame = Protocol.encode(cmd)
    write_frame(state, frame)
    {:reply, :ok, state}
  end

  def handle_call(:stop_all, _from, state) do
    write_frame(state, Protocol.encode_idle())
    {:reply, :ok, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, not state.virtual, state}
  end

  @impl true
  def terminate(_reason, %{virtual: false, uart_pid: pid} = _state) when is_pid(pid) do
    Circuits.UART.write(pid, Protocol.encode_idle())
    Circuits.UART.close(pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp write_frame(%{virtual: true}, frame) do
    Logger.debug("[MotorController] #{inspect(frame, base: :hex)}")
    :ok
  end

  defp write_frame(%{uart_pid: pid}, frame) do
    Logger.debug("[MotorController] #{inspect(frame, base: :hex)}")

    case Circuits.UART.write(pid, frame) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[MotorController] Write failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
