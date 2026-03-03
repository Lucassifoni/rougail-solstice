defmodule RougailSolstice.Robot.ServerTest do
  use ExUnit.Case

  alias RougailSolstice.Robot.Capture
  alias RougailSolstice.Robot.Server
  alias RougailSolstice.Robot.State

  setup do
    name = :"test_server_#{System.unique_integer()}"
    {:ok, pid} = Server.start_link(name: name)
    %{server: name, pid: pid}
  end

  describe "start_link/1" do
    test "starts with default configuration" do
      name = :"start_test_#{System.unique_integer()}"
      assert {:ok, _pid} = Server.start_link(name: name)

      state = Server.get_state(name)
      assert state.axes.x.position == 500
      assert state.axes.y.position == 500
      assert state.axes.z.position == 0
    end

    test "starts with custom configuration" do
      name = :"custom_test_#{System.unique_integer()}"

      config = %{
        x: %{min: 0, max: 100, initial: 25},
        y: %{min: 0, max: 100, initial: 50},
        z: %{min: 0, max: 100, initial: 75}
      }

      assert {:ok, _pid} = Server.start_link(name: name, config: config)

      state = Server.get_state(name)
      assert state.axes.x.position == 25
      assert state.axes.y.position == 50
      assert state.axes.z.position == 75
    end
  end

  describe "get_state/1" do
    test "returns current state", %{server: server} do
      state = Server.get_state(server)
      assert %State{} = state
    end
  end

  describe "move_axis/3" do
    test "moves axis by delta", %{server: server} do
      assert {:ok, state} = Server.move_axis(server, :x, 100)
      assert state.axes.x.position == 600
    end

    test "returns error for invalid move", %{server: server} do
      assert {:error, :above_maximum} = Server.move_axis(server, :x, 501)
    end
  end

  describe "camera operations" do
    test "lock, take picture, release workflow", %{server: server} do
      assert {:ok, locked} = Server.lock_camera(server)
      assert locked.camera.status == :locked

      assert {:ok, captured, capture} = Server.take_picture(server)
      assert %Capture{} = capture
      assert captured.camera.last_capture == capture

      assert {:ok, released} = Server.release_camera(server)
      assert released.camera.status == :idle
    end

    test "returns error when taking picture without lock", %{server: server} do
      assert {:error, :camera_not_locked} = Server.take_picture(server)
    end

    test "returns error when locking already locked camera", %{server: server} do
      {:ok, _} = Server.lock_camera(server)
      assert {:error, :already_locked} = Server.lock_camera(server)
    end
  end

  describe "pubsub" do
    test "broadcasts state changes on move", %{server: server} do
      Server.subscribe()
      {:ok, _} = Server.move_axis(server, :x, 50)

      assert_receive {:robot_state_changed, state}
      assert state.axes.x.position == 550
    end

    test "broadcasts state changes on camera operations", %{server: server} do
      Server.subscribe()

      {:ok, _} = Server.lock_camera(server)
      assert_receive {:robot_state_changed, state}
      assert state.camera.status == :locked

      {:ok, _, _} = Server.take_picture(server)
      assert_receive {:robot_state_changed, state}
      assert state.camera.last_capture != nil

      {:ok, _} = Server.release_camera(server)
      assert_receive {:robot_state_changed, state}
      assert state.camera.status == :idle
    end
  end
end
