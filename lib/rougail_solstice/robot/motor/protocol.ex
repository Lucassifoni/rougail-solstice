defmodule RougailSolstice.Robot.Motor.Protocol do
  @moduledoc """
  Binary encoding for the motor control protocol.

  Frame format (5 bytes):
    Byte 0: sync byte (0xAA)
    Byte 1 (flags): [ax1_en, ax1_dir, ax2_en, ax2_dir, ax3_en, ax3_dir, 0, 0]
    Byte 2: axis1 speed (0-255)
    Byte 3: axis2 speed (0-255)
    Byte 4: axis3 speed (0-255)
  """

  import Bitwise

  alias RougailSolstice.Robot.Motor.Command

  @sync_byte 0xAA

  @spec encode(Command.t()) :: <<_::40>>
  def encode(%Command{} = cmd) do
    flags = encode_flags(cmd)
    <<@sync_byte, flags::8, cmd.axis1.speed::8, cmd.axis2.speed::8, cmd.axis3.speed::8>>
  end

  @spec encode_idle() :: <<_::40>>
  def encode_idle, do: <<@sync_byte, 0, 0, 0, 0>>

  defp encode_flags(%Command{} = cmd) do
    encode_axis_flags(cmd.axis1, 6) |||
      encode_axis_flags(cmd.axis2, 4) |||
      encode_axis_flags(cmd.axis3, 2)
  end

  defp encode_axis_flags(%{enabled: false}, _shift), do: 0

  defp encode_axis_flags(%{enabled: true, direction: dir}, shift) do
    dir_bit = if dir == :positive, do: 1, else: 0
    1 <<< (shift + 1) ||| dir_bit <<< shift
  end
end
