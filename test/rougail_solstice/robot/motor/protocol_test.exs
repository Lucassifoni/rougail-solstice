defmodule RougailSolstice.Robot.Motor.ProtocolTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias RougailSolstice.Robot.Motor.{Command, Protocol}

  @sync 0xAA

  describe "encode_idle/0" do
    test "returns sync byte followed by 4 zero bytes" do
      assert Protocol.encode_idle() == <<@sync, 0, 0, 0, 0>>
    end
  end

  describe "encode/1" do
    test "idle command encodes to sync + all zeros" do
      assert Protocol.encode(Command.idle()) == <<@sync, 0, 0, 0, 0>>
    end

    test "all frames start with sync byte" do
      cmd = Command.idle() |> Command.set_axis(:axis1, :positive, 30)
      <<sync, _::binary>> = Protocol.encode(cmd)
      assert sync == @sync
    end

    test "single axis enabled positive" do
      cmd = Command.idle() |> Command.set_axis(:axis1, :positive, 30)

      <<@sync, flags, s1, s2, s3>> = Protocol.encode(cmd)

      assert s1 == 30
      assert s2 == 0
      assert s3 == 0
      assert (flags &&& 0b11000000) == 0b11000000
      assert (flags &&& 0b00111100) == 0b00000000
    end

    test "single axis enabled negative" do
      cmd = Command.idle() |> Command.set_axis(:axis2, :negative, 20)

      <<@sync, flags, s1, s2, s3>> = Protocol.encode(cmd)

      assert s1 == 0
      assert s2 == 20
      assert s3 == 0
      assert (flags &&& 0b00110000) == 0b00100000
    end

    test "all axes enabled with different speeds and directions" do
      cmd =
        Command.idle()
        |> Command.set_axis(:axis1, :positive, 45)
        |> Command.set_axis(:axis2, :negative, 25)
        |> Command.set_axis(:axis3, :positive, 1)

      <<@sync, flags, s1, s2, s3>> = Protocol.encode(cmd)

      assert s1 == 45
      assert s2 == 25
      assert s3 == 1

      assert (flags >>> 6 &&& 0b11) == 0b11
      assert (flags >>> 4 &&& 0b11) == 0b10
      assert (flags >>> 2 &&& 0b11) == 0b11
      assert (flags &&& 0b11) == 0b00
    end

    test "flag bit positions are correct" do
      <<@sync, flags, _, _, _>> =
        Command.idle()
        |> Command.set_axis(:axis1, :positive, 1)
        |> Protocol.encode()

      assert flags == 0b11000000

      <<@sync, flags, _, _, _>> =
        Command.idle()
        |> Command.set_axis(:axis1, :negative, 1)
        |> Protocol.encode()

      assert flags == 0b10000000

      <<@sync, flags, _, _, _>> =
        Command.idle()
        |> Command.set_axis(:axis2, :positive, 1)
        |> Protocol.encode()

      assert flags == 0b00110000

      <<@sync, flags, _, _, _>> =
        Command.idle()
        |> Command.set_axis(:axis3, :negative, 1)
        |> Protocol.encode()

      assert flags == 0b00001000
    end

    test "disabled axis with speed still encodes speed but not enable flag" do
      cmd =
        Command.idle()
        |> Command.set_speed(:axis1, 30)
        |> Command.set_direction(:axis1, :positive)

      <<@sync, flags, s1, _, _>> = Protocol.encode(cmd)

      assert s1 == 30
      assert (flags &&& 0b10000000) == 0
    end
  end
end
