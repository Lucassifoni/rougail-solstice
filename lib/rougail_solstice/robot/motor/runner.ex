defmodule RougailSolstice.Robot.Motor.Runner do
  @moduledoc """
  Executes a parsed motor program by sending commands via the controller
  with appropriate timing. Runs as a Task. Reports progress via PubSub.
  """

  require Logger

  alias RougailSolstice.Robot.Motor.{Command, Controller, Program}

  @pubsub RougailSolstice.PubSub

  @spec run(GenServer.server(), [Program.instruction()], keyword()) :: :ok | {:error, term()}
  def run(controller, instructions, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    total = length(instructions)

    try do
      instructions
      |> Enum.with_index()
      |> Enum.reduce(Command.idle(), fn {instruction, index}, acc ->
        broadcast_progress(session_id, index, total)
        execute(controller, instruction, acc)
      end)

      Controller.stop_all(controller)
      broadcast_progress(session_id, total, total)
      :ok
    rescue
      e ->
        Controller.stop_all(controller)
        Logger.error("[Runner] Program failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp execute(_controller, {:set_speed, axis, speed}, acc) do
    Command.set_speed(acc, axis, speed)
  end

  defp execute(_controller, {:set_direction, axis, direction}, acc) do
    Command.set_direction(acc, axis, direction)
  end

  defp execute(controller, {:step, axis, ms}, acc) do
    cmd = Command.enable(acc, axis)
    Controller.send_command(controller, cmd)
    Process.sleep(ms)
    Controller.stop_all(controller)
    Command.disable(acc, axis)
  end

  defp execute(_controller, {:sleep, ms}, acc) do
    Process.sleep(ms)
    acc
  end

  defp execute(controller, :stop, _acc) do
    Controller.stop_all(controller)
    Command.idle()
  end

  defp broadcast_progress(nil, _index, _total), do: :ok

  defp broadcast_progress(session_id, index, total) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "motor:#{session_id}",
      {:program_progress, index, total}
    )
  end
end
