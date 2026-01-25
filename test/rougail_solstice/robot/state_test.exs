defmodule RougailSolstice.Robot.StateTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Robot.CameraAdapter
  alias RougailSolstice.Robot.Capture
  alias RougailSolstice.Robot.State

  describe "new/1" do
    test "creates state with default configuration" do
      assert {:ok, state} = State.new()
      assert state.axes.x.position == 500
      assert state.axes.y.position == 500
      assert state.axes.z.position == 0
      assert state.camera.status == :idle
      assert state.camera_adapter == CameraAdapter.Virtual
    end

    test "creates state with custom configuration" do
      config = %{
        x: %{min: 0, max: 100, initial: 50},
        y: %{min: -50, max: 50, initial: 0},
        z: %{min: 0, max: 200, initial: 100}
      }

      assert {:ok, state} = State.new(config)
      assert state.axes.x.position == 50
      assert state.axes.x.max == 100
      assert state.axes.y.position == 0
      assert state.axes.y.min == -50
      assert state.axes.z.position == 100
    end

    test "rejects invalid configuration" do
      config = %{
        x: %{min: 100, max: 0, initial: 50},
        y: %{min: 0, max: 100, initial: 50},
        z: %{min: 0, max: 100, initial: 50}
      }

      assert {:error, :invalid_bounds} = State.new(config)
    end
  end

  describe "move_axis/3" do
    setup do
      {:ok, state} = State.new()
      %{state: state}
    end

    test "moves x axis", %{state: state} do
      assert {:ok, moved} = State.move_axis(state, :x, 100)
      assert moved.axes.x.position == 600
      assert moved.axes.y.position == 500
      assert moved.axes.z.position == 0
    end

    test "moves y axis", %{state: state} do
      assert {:ok, moved} = State.move_axis(state, :y, -200)
      assert moved.axes.y.position == 300
    end

    test "moves z axis", %{state: state} do
      assert {:ok, moved} = State.move_axis(state, :z, 250)
      assert moved.axes.z.position == 250
    end

    test "rejects move beyond maximum", %{state: state} do
      assert {:error, :above_maximum} = State.move_axis(state, :x, 501)
    end

    test "rejects move below minimum", %{state: state} do
      assert {:error, :below_minimum} = State.move_axis(state, :x, -501)
    end
  end

  describe "set_axis_position/3" do
    setup do
      {:ok, state} = State.new()
      %{state: state}
    end

    test "sets axis to specific position", %{state: state} do
      assert {:ok, updated} = State.set_axis_position(state, :x, 750)
      assert updated.axes.x.position == 750
    end

    test "rejects position out of bounds", %{state: state} do
      assert {:error, :above_maximum} = State.set_axis_position(state, :x, 1001)
    end
  end

  describe "lock_camera/1" do
    setup do
      {:ok, state} = State.new()
      %{state: state}
    end

    test "locks camera", %{state: state} do
      assert {:ok, locked} = State.lock_camera(state)
      assert locked.camera.status == :locked
    end

    test "rejects locking already locked camera", %{state: state} do
      {:ok, locked} = State.lock_camera(state)
      assert {:error, :already_locked} = State.lock_camera(locked)
    end
  end

  describe "take_picture/1" do
    setup do
      {:ok, state} = State.new()
      {:ok, locked} = State.lock_camera(state)
      %{state: state, locked: locked}
    end

    test "takes picture with current position", %{locked: state} do
      assert {:ok, updated, capture} = State.take_picture(state)
      assert %Capture{} = capture
      assert capture.position == %{x: 500, y: 500, z: 0}
      assert is_binary(capture.image_binary)
      assert byte_size(capture.image_binary) > 0
      assert capture.content_type in ["image/jpeg", "image/png"]
      assert updated.camera.last_capture == capture
    end

    test "captures position after movement", %{locked: state} do
      {:ok, moved} = State.move_axis(state, :x, 100)
      {:ok, moved} = State.move_axis(moved, :y, -50)
      {:ok, moved} = State.move_axis(moved, :z, 25)

      assert {:ok, _, capture} = State.take_picture(moved)
      assert capture.position == %{x: 600, y: 450, z: 25}
    end

    test "rejects taking picture when camera not locked", %{state: state} do
      assert {:error, :camera_not_locked} = State.take_picture(state)
    end
  end

  describe "release_camera/1" do
    setup do
      {:ok, state} = State.new()
      {:ok, locked} = State.lock_camera(state)
      %{state: state, locked: locked}
    end

    test "releases locked camera", %{locked: state} do
      assert {:ok, released} = State.release_camera(state)
      assert released.camera.status == :idle
    end

    test "rejects releasing idle camera", %{state: state} do
      assert {:error, :camera_not_locked} = State.release_camera(state)
    end
  end

  describe "get_position/1" do
    test "returns current position of all axes" do
      {:ok, state} = State.new()
      assert State.get_position(state) == %{x: 500, y: 500, z: 0}
    end
  end

  describe "full workflow" do
    test "move axes, lock, capture, release" do
      {:ok, state} = State.new()

      {:ok, state} = State.move_axis(state, :x, 100)
      {:ok, state} = State.move_axis(state, :y, -100)
      {:ok, state} = State.move_axis(state, :z, 50)

      {:ok, state} = State.lock_camera(state)
      {:ok, state, capture} = State.take_picture(state)
      {:ok, state} = State.release_camera(state)

      assert capture.position == %{x: 600, y: 400, z: 50}
      assert state.camera.status == :idle
      assert state.camera.last_capture == capture
    end
  end
end
