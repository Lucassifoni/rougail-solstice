defmodule RougailSolstice.Robot.Motor.Program do
  @moduledoc """
  Parser for the motor control DSL.

  Syntax (case-insensitive, one instruction per line):
    X speed 50        # set axis speed (0-75)
    X positive        # set axis direction
    X negative
    X step 10         # send current state, hold 10ms, then stop
    sleep 300         # wait 300ms (motors keep running)
    stop              # all-stop, disable drivers
    # comment
  """

  @type axis :: :axis1 | :axis2 | :axis3
  @type instruction ::
          {:set_speed, axis(), non_neg_integer()}
          | {:set_direction, axis(), :positive | :negative}
          | {:step, axis(), pos_integer()}
          | {:sleep, pos_integer()}
          | :stop

  @axis_map %{"x" => :axis1, "y" => :axis2, "z" => :axis3}

  @spec parse(String.t()) :: {:ok, [instruction()]} | {:error, {pos_integer(), String.t()}}
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {line, line_no}, acc ->
      line = line |> String.trim() |> strip_comment()

      if line == "" do
        {:cont, acc}
      else
        case parse_line(String.downcase(line)) do
          {:ok, instruction} -> {:cont, [instruction | acc]}
          {:error, reason} -> {:halt, {:error, {line_no, reason}}}
        end
      end
    end)
    |> case do
      {:error, _} = err -> err
      instructions -> {:ok, Enum.reverse(instructions)}
    end
  end

  defp strip_comment(line) do
    case String.split(line, "#", parts: 2) do
      [before, _] -> String.trim(before)
      [only] -> only
    end
  end

  defp parse_line("stop"), do: {:ok, :stop}

  defp parse_line("sleep " <> rest) do
    case parse_positive_int(String.trim(rest)) do
      {:ok, ms} -> {:ok, {:sleep, ms}}
      :error -> {:error, "invalid sleep duration"}
    end
  end

  defp parse_line(line) do
    case String.split(line, " ", parts: 3) do
      [axis_str, command] ->
        parse_axis_command(axis_str, command, nil)

      [axis_str, command, arg] ->
        parse_axis_command(axis_str, command, arg)

      _ ->
        {:error, "unrecognized instruction: #{line}"}
    end
  end

  defp parse_axis_command(axis_str, command, arg) do
    case Map.fetch(@axis_map, axis_str) do
      {:ok, axis} -> dispatch_axis_command(axis, command, arg)
      :error -> {:error, "unknown axis: #{axis_str}"}
    end
  end

  defp dispatch_axis_command(axis, "positive", nil), do: {:ok, {:set_direction, axis, :positive}}
  defp dispatch_axis_command(axis, "negative", nil), do: {:ok, {:set_direction, axis, :negative}}
  defp dispatch_axis_command(axis, "forward", nil), do: {:ok, {:set_direction, axis, :positive}}
  defp dispatch_axis_command(axis, "backward", nil), do: {:ok, {:set_direction, axis, :negative}}

  defp dispatch_axis_command(axis, "speed", arg) when is_binary(arg) do
    max = RougailSolstice.Robot.Motor.Command.max_speed()

    case parse_positive_int(String.trim(arg)) do
      {:ok, speed} when speed <= max -> {:ok, {:set_speed, axis, speed}}
      {:ok, _} -> {:error, "speed must be 0-#{max}"}
      :error -> {:error, "invalid speed value"}
    end
  end

  defp dispatch_axis_command(axis, "step", arg) when is_binary(arg) do
    case parse_positive_int(String.trim(arg)) do
      {:ok, ms} -> {:ok, {:step, axis, ms}}
      :error -> {:error, "invalid step duration"}
    end
  end

  defp dispatch_axis_command(_axis, cmd, _arg), do: {:error, "unknown command: #{cmd}"}

  defp parse_positive_int(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end
end
