defmodule RougailSolstice.Robot.CameraTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Robot.Camera
  alias RougailSolstice.Robot.CameraAdapter
  alias RougailSolstice.Robot.Capture

  describe "new/0" do
    test "creates camera in idle state" do
      camera = Camera.new()
      assert camera.status == :idle
      assert camera.last_capture == nil
    end
  end

  describe "lock/1" do
    test "locks idle camera" do
      camera = Camera.new()
      assert {:ok, locked} = Camera.lock(camera)
      assert locked.status == :locked
    end

    test "rejects locking already locked camera" do
      camera = Camera.new()
      {:ok, locked} = Camera.lock(camera)
      assert {:error, :already_locked} = Camera.lock(locked)
    end
  end

  describe "take_picture/3" do
    test "takes picture when camera is locked" do
      camera = Camera.new()
      {:ok, locked} = Camera.lock(camera)
      position = %{x: 100, y: 200, z: 50}

      assert {:ok, updated, capture} =
               Camera.take_picture(locked, position, CameraAdapter.Virtual)

      assert %Capture{} = capture
      assert capture.position == position
      assert is_binary(capture.image_binary)
      assert byte_size(capture.image_binary) > 0
      assert capture.content_type in ["image/jpeg", "image/png"]
      assert updated.last_capture == capture
      assert updated.status == :locked
    end

    test "can take multiple pictures while locked" do
      camera = Camera.new()
      {:ok, locked} = Camera.lock(camera)

      {:ok, camera1, capture1} =
        Camera.take_picture(locked, %{x: 100, y: 200, z: 50}, CameraAdapter.Virtual)

      {:ok, camera2, capture2} =
        Camera.take_picture(camera1, %{x: 150, y: 250, z: 75}, CameraAdapter.Virtual)

      assert camera1.last_capture == capture1
      assert camera2.last_capture == capture2
      assert capture1.position != capture2.position
    end

    test "rejects taking picture when camera is idle" do
      camera = Camera.new()

      assert {:error, :camera_not_locked} =
               Camera.take_picture(camera, %{x: 0, y: 0, z: 0}, CameraAdapter.Virtual)
    end
  end

  describe "release/1" do
    test "releases locked camera" do
      camera = Camera.new()
      {:ok, locked} = Camera.lock(camera)
      assert {:ok, released} = Camera.release(locked)
      assert released.status == :idle
    end

    test "preserves last capture after release" do
      camera = Camera.new()
      {:ok, locked} = Camera.lock(camera)

      {:ok, with_capture, _} =
        Camera.take_picture(locked, %{x: 100, y: 200, z: 50}, CameraAdapter.Virtual)

      {:ok, released} = Camera.release(with_capture)

      assert released.status == :idle
      assert released.last_capture != nil
    end

    test "rejects releasing idle camera" do
      camera = Camera.new()
      assert {:error, :camera_not_locked} = Camera.release(camera)
    end
  end

  describe "full workflow" do
    test "lock -> take picture -> release cycle" do
      camera = Camera.new()

      assert {:ok, locked} = Camera.lock(camera)
      assert locked.status == :locked

      assert {:ok, with_capture, capture} =
               Camera.take_picture(locked, %{x: 500, y: 500, z: 250}, CameraAdapter.Virtual)

      assert with_capture.last_capture == capture

      assert {:ok, released} = Camera.release(with_capture)
      assert released.status == :idle
      assert released.last_capture == capture
    end
  end
end
