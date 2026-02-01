defmodule RougailSolstice.Robot.Motor.CommandTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Robot.Motor.Command

  describe "max_speed/0" do
    test "returns 75" do
      assert Command.max_speed() == 75
    end
  end

  describe "idle/0" do
    test "returns all axes disabled with zero speed" do
      cmd = Command.idle()
      assert cmd.axis1 == %{enabled: false, direction: :positive, speed: 0}
      assert cmd.axis2 == %{enabled: false, direction: :positive, speed: 0}
      assert cmd.axis3 == %{enabled: false, direction: :positive, speed: 0}
    end
  end

  describe "set_speed/3" do
    test "sets speed for a specific axis" do
      cmd = Command.idle() |> Command.set_speed(:axis1, 30)
      assert cmd.axis1.speed == 30
      assert cmd.axis2.speed == 0
    end

    test "clamps speed at max_speed" do
      cmd = Command.idle() |> Command.set_speed(:axis2, 200)
      assert cmd.axis2.speed == 75
    end

    test "allows zero" do
      cmd = Command.idle() |> Command.set_speed(:axis2, 0)
      assert cmd.axis2.speed == 0
    end

    test "allows max_speed exactly" do
      cmd = Command.idle() |> Command.set_speed(:axis2, 75)
      assert cmd.axis2.speed == 75
    end
  end

  describe "set_direction/3" do
    test "sets direction to positive" do
      cmd = Command.idle() |> Command.set_direction(:axis1, :positive)
      assert cmd.axis1.direction == :positive
    end

    test "sets direction to negative" do
      cmd = Command.idle() |> Command.set_direction(:axis3, :negative)
      assert cmd.axis3.direction == :negative
    end
  end

  describe "enable/2 and disable/2" do
    test "enables an axis" do
      cmd = Command.idle() |> Command.enable(:axis2)
      assert cmd.axis2.enabled == true
      assert cmd.axis1.enabled == false
    end

    test "disables an axis" do
      cmd =
        Command.idle()
        |> Command.enable(:axis2)
        |> Command.disable(:axis2)

      assert cmd.axis2.enabled == false
    end
  end

  describe "set_axis/4" do
    test "sets direction, speed and enables in one call" do
      cmd = Command.idle() |> Command.set_axis(:axis1, :negative, 30)
      assert cmd.axis1 == %{enabled: true, direction: :negative, speed: 30}
    end

    test "clamps speed at max_speed" do
      cmd = Command.idle() |> Command.set_axis(:axis1, :positive, 999)
      assert cmd.axis1.speed == 75
    end

    test "does not affect other axes" do
      cmd = Command.idle() |> Command.set_axis(:axis2, :positive, 20)
      assert cmd.axis1 == %{enabled: false, direction: :positive, speed: 0}
      assert cmd.axis3 == %{enabled: false, direction: :positive, speed: 0}
    end
  end

  describe "composition" do
    test "multiple operations compose correctly" do
      cmd =
        Command.idle()
        |> Command.set_speed(:axis1, 40)
        |> Command.set_direction(:axis1, :negative)
        |> Command.enable(:axis1)
        |> Command.set_speed(:axis3, 10)
        |> Command.set_direction(:axis3, :positive)
        |> Command.enable(:axis3)

      assert cmd.axis1 == %{enabled: true, direction: :negative, speed: 40}
      assert cmd.axis2 == %{enabled: false, direction: :positive, speed: 0}
      assert cmd.axis3 == %{enabled: true, direction: :positive, speed: 10}
    end
  end
end
