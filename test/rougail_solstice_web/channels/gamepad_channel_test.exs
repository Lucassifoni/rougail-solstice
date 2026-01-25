defmodule RougailSolsticeWeb.GamepadChannelTest do
  use RougailSolsticeWeb.ChannelCase

  alias RougailSolstice.Interferometry.Server, as: InterfServer
  alias RougailSolstice.OpticalPieces
  alias RougailSolstice.Robot.Server, as: RobotServer
  alias RougailSolstice.Sessions.SessionManager

  setup do
    {:ok, optical_piece} =
      OpticalPieces.create_optical_piece(%{
        name: "Test Mirror #{System.unique_integer([:positive])}",
        diameter: 200.0,
        roc: 2000.0
      })

    {:ok, session_id} = SessionManager.open_session(optical_piece.id)
    servers = SessionManager.session_servers(session_id)

    {:ok, _, socket} =
      RougailSolsticeWeb.UserSocket
      |> socket("user_id", %{})
      |> subscribe_and_join(RougailSolsticeWeb.GamepadChannel, "gamepad:control:#{session_id}")

    on_exit(fn ->
      SessionManager.close_session(session_id)
    end)

    %{socket: socket, session_id: session_id, servers: servers}
  end

  describe "join" do
    test "fails for non-existent session" do
      assert {:error, %{reason: "session_not_found"}} =
               RougailSolsticeWeb.UserSocket
               |> socket("user_id", %{})
               |> subscribe_and_join(RougailSolsticeWeb.GamepadChannel, "gamepad:control:999999")
    end
  end

  describe "move_axis" do
    test "moves axis by delta", %{socket: socket, servers: servers} do
      initial = RobotServer.get_state(servers.robot)
      push(socket, "move_axis", %{"axis" => "x", "delta" => 50})
      Process.sleep(50)
      updated = RobotServer.get_state(servers.robot)
      assert updated.axes.x.position == initial.axes.x.position + 50
    end
  end

  describe "toggle_liveview" do
    test "toggles liveview state", %{socket: socket, servers: servers} do
      initial = InterfServer.get_state(servers.interferometry)
      assert initial.liveview_active == false

      push(socket, "toggle_liveview", %{})
      Process.sleep(50)

      updated = InterfServer.get_state(servers.interferometry)
      assert updated.liveview_active == true

      RobotServer.release_camera(servers.robot)
    end
  end

  describe "adjust_outline_position" do
    test "adjusts outline position", %{socket: socket, servers: servers} do
      initial = InterfServer.get_state(servers.interferometry)
      push(socket, "adjust_outline_position", %{"dx" => 10, "dy" => -5})
      Process.sleep(50)
      updated = InterfServer.get_state(servers.interferometry)
      assert updated.outline_circle.cx == initial.outline_circle.cx + 10
      assert updated.outline_circle.cy == initial.outline_circle.cy - 5
    end
  end

  describe "adjust_outline_radius" do
    test "adjusts outline radius", %{socket: socket, servers: servers} do
      initial = InterfServer.get_state(servers.interferometry)
      push(socket, "adjust_outline_radius", %{"delta" => 15})
      Process.sleep(50)
      updated = InterfServer.get_state(servers.interferometry)
      assert updated.outline_circle.r == initial.outline_circle.r + 15
    end
  end

  describe "adjust_center_filter_radius" do
    test "adjusts center filter radius", %{socket: socket, servers: servers} do
      initial = InterfServer.get_state(servers.interferometry)
      push(socket, "adjust_center_filter_radius", %{"delta" => 3})
      Process.sleep(50)
      updated = InterfServer.get_state(servers.interferometry)
      assert updated.center_filter_radius == initial.center_filter_radius + 3
    end
  end
end
