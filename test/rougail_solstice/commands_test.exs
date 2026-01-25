defmodule RougailSolstice.CommandsTest do
  use ExUnit.Case, async: false

  alias RougailSolstice.Commands
  alias RougailSolstice.Interferometry.Server, as: InterfServer
  alias RougailSolstice.Robot.Server, as: RobotServer

  setup do
    robot_name = :"robot_#{System.unique_integer([:positive])}"
    interf_name = :"interf_#{System.unique_integer([:positive])}"

    start_supervised!({RobotServer, name: robot_name})
    start_supervised!({InterfServer, name: interf_name})

    %{robot: robot_name, interf: interf_name}
  end

  describe "move_axis/2" do
    test "moves axis by delta", %{robot: robot} do
      initial = RobotServer.get_state(robot)
      assert {:ok, state} = Commands.move_axis(robot, :x, 100)
      assert state.axes.x.position == initial.axes.x.position + 100
    end

    test "returns error for invalid axis", %{robot: robot} do
      assert_raise FunctionClauseError, fn ->
        Commands.move_axis(robot, :invalid, 100)
      end
    end

    test "returns error when exceeding bounds", %{robot: robot} do
      assert {:error, :above_maximum} = Commands.move_axis(robot, :x, 10_000)
    end
  end

  describe "set_axis_position/2" do
    test "sets axis to absolute position", %{robot: robot} do
      assert {:ok, state} = Commands.set_axis_position(robot, :y, 250)
      assert state.axes.y.position == 250
    end
  end

  describe "lock_camera/0 and release_camera/0" do
    test "locks and releases camera", %{robot: robot} do
      assert {:ok, locked} = Commands.lock_camera(robot)
      assert locked.camera.status == :locked

      assert {:ok, released} = Commands.release_camera(robot)
      assert released.camera.status == :idle
    end
  end

  describe "take_picture/0" do
    @tag timeout: 30_000
    test "captures when camera is locked", %{robot: robot} do
      {:ok, _} = Commands.lock_camera(robot)
      assert {:ok, _state, capture} = Commands.take_picture(robot)
      assert capture.image_path != nil
    end

    test "fails when camera not locked", %{robot: robot} do
      assert {:error, :camera_not_locked} = Commands.take_picture(robot)
    end
  end

  describe "toggle_liveview/0" do
    test "starts liveview when inactive", %{robot: robot, interf: interf} do
      initial = InterfServer.get_state(interf)
      assert initial.liveview_active == false

      assert {:ok, state} = Commands.toggle_liveview(robot, interf)
      assert state.liveview_active == true
    end

    test "stops liveview when active", %{robot: robot, interf: interf} do
      {:ok, _} = Commands.toggle_liveview(robot, interf)
      assert {:ok, state} = Commands.toggle_liveview(robot, interf)
      assert state.liveview_active == false
    end
  end

  describe "start_liveview/0 and stop_liveview/0" do
    test "starts and stops liveview", %{robot: robot, interf: interf} do
      assert {:ok, started} = Commands.start_liveview(robot, interf)
      assert started.liveview_active == true

      assert {:ok, stopped} = Commands.stop_liveview(robot, interf)
      assert stopped.liveview_active == false
    end
  end

  describe "set_outline_circle/3" do
    test "sets outline circle coordinates", %{interf: interf} do
      assert {:ok, state} = Commands.set_outline_circle(interf, 100, 200, 50)
      assert state.outline_circle == %{cx: 100, cy: 200, r: 50}
    end
  end

  describe "adjust_outline_position/2" do
    test "adjusts outline position by delta", %{interf: interf} do
      {:ok, _} = Commands.set_outline_circle(interf, 100, 100, 50)
      assert {:ok, state} = Commands.adjust_outline_position(interf, 10, -20)
      assert state.outline_circle.cx == 110
      assert state.outline_circle.cy == 80
      assert state.outline_circle.r == 50
    end
  end

  describe "adjust_outline_radius/1" do
    test "adjusts outline radius by delta", %{interf: interf} do
      {:ok, _} = Commands.set_outline_circle(interf, 100, 100, 50)
      assert {:ok, state} = Commands.adjust_outline_radius(interf, 10)
      assert state.outline_circle.r == 60
    end

    test "clamps radius to minimum of 1", %{interf: interf} do
      {:ok, _} = Commands.set_outline_circle(interf, 100, 100, 5)
      assert {:ok, state} = Commands.adjust_outline_radius(interf, -100)
      assert state.outline_circle.r == 1
    end
  end

  describe "set_center_filter_radius/1" do
    test "sets center filter radius", %{interf: interf} do
      assert {:ok, state} = Commands.set_center_filter_radius(interf, 25)
      assert state.center_filter_radius == 25
    end

    test "rejects non-positive radius", %{interf: interf} do
      assert {:error, :invalid_radius} = Commands.set_center_filter_radius(interf, 0)
      assert {:error, :invalid_radius} = Commands.set_center_filter_radius(interf, -5)
    end
  end

  describe "adjust_center_filter_radius/1" do
    test "adjusts center filter radius by delta", %{interf: interf} do
      {:ok, _} = Commands.set_center_filter_radius(interf, 10)
      assert {:ok, state} = Commands.adjust_center_filter_radius(interf, 5)
      assert state.center_filter_radius == 15
    end

    test "clamps radius to minimum of 1", %{interf: interf} do
      {:ok, _} = Commands.set_center_filter_radius(interf, 5)
      assert {:ok, state} = Commands.adjust_center_filter_radius(interf, -100)
      assert state.center_filter_radius == 1
    end
  end
end
