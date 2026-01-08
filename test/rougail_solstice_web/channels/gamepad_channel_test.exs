defmodule RougailSolsticeWeb.GamepadChannelTest do
  use RougailSolsticeWeb.ChannelCase

  alias RougailSolstice.Interferometry.Server, as: InterfServer
  alias RougailSolstice.Robot.Server, as: RobotServer

  setup do
    RobotServer.reset()
    InterfServer.reset()

    {:ok, _, socket} =
      RougailSolsticeWeb.UserSocket
      |> socket("user_id", %{})
      |> subscribe_and_join(RougailSolsticeWeb.GamepadChannel, "gamepad:control")

    %{socket: socket}
  end

  describe "move_axis" do
    test "moves axis by delta", %{socket: socket} do
      initial = RobotServer.get_state()
      push(socket, "move_axis", %{"axis" => "x", "delta" => 50})
      Process.sleep(50)
      updated = RobotServer.get_state()
      assert updated.axes.x.position == initial.axes.x.position + 50
    end
  end

  describe "toggle_liveview" do
    test "toggles liveview state", %{socket: socket} do
      initial = InterfServer.get_state()
      assert initial.liveview_active == false

      push(socket, "toggle_liveview", %{})
      Process.sleep(50)

      updated = InterfServer.get_state()
      assert updated.liveview_active == true

      RobotServer.release_camera()
    end
  end

  describe "adjust_outline_position" do
    test "adjusts outline position", %{socket: socket} do
      initial = InterfServer.get_state()
      push(socket, "adjust_outline_position", %{"dx" => 10, "dy" => -5})
      Process.sleep(50)
      updated = InterfServer.get_state()
      assert updated.outline_circle.cx == initial.outline_circle.cx + 10
      assert updated.outline_circle.cy == initial.outline_circle.cy - 5
    end
  end

  describe "adjust_outline_radius" do
    test "adjusts outline radius", %{socket: socket} do
      initial = InterfServer.get_state()
      push(socket, "adjust_outline_radius", %{"delta" => 15})
      Process.sleep(50)
      updated = InterfServer.get_state()
      assert updated.outline_circle.r == initial.outline_circle.r + 15
    end
  end

  describe "adjust_center_filter_radius" do
    test "adjusts center filter radius", %{socket: socket} do
      initial = InterfServer.get_state()
      push(socket, "adjust_center_filter_radius", %{"delta" => 3})
      Process.sleep(50)
      updated = InterfServer.get_state()
      assert updated.center_filter_radius == initial.center_filter_radius + 3
    end
  end
end
