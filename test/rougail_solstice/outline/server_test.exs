defmodule RougailSolstice.Outline.ServerTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.ImageStore
  alias RougailSolstice.Outline.Server, as: OutlineServer

  setup do
    {:ok, image_store} =
      start_supervised(
        {ImageStore, name: :"test_outline_image_store_#{:erlang.unique_integer()}"}
      )

    test_pid = self()

    {:ok, server} =
      start_supervised(
        {OutlineServer,
         name: :"test_outline_server_#{:erlang.unique_integer()}",
         session_id: 1,
         image_store: image_store,
         on_circle_detected: fn circle ->
           send(test_pid, {:circle_detected, circle})
         end}
      )

    %{server: server, image_store: image_store}
  end

  describe "enable/disable" do
    test "enables and disables detection", %{server: server} do
      refute OutlineServer.enabled?(server)

      :ok = OutlineServer.enable(server)
      assert OutlineServer.enabled?(server)

      :ok = OutlineServer.disable(server)
      refute OutlineServer.enabled?(server)
    end
  end

  describe "push_frame/3" do
    test "accepts frame when enabled", %{server: server} do
      :ok = OutlineServer.enable(server)

      binary = <<0, 1, 2, 3, 4, 5>>
      dims = {640, 480}

      :ok = OutlineServer.push_frame(server, binary, dims)

      state = OutlineServer.get_state(server)
      assert :queue.len(state.frames) == 1
    end

    test "ignores frame when disabled", %{server: server} do
      binary = <<0, 1, 2, 3, 4, 5>>
      dims = {640, 480}

      :ok = OutlineServer.push_frame(server, binary, dims)

      state = OutlineServer.get_state(server)
      assert :queue.len(state.frames) == 0
    end
  end

  describe "update_detection_params/2" do
    test "updates detection params", %{server: server} do
      params = %{min_radius: 50, max_radius: 300}
      :ok = OutlineServer.update_detection_params(server, params)

      state = OutlineServer.get_state(server)
      assert state.detection_params.min_radius == 50
      assert state.detection_params.max_radius == 300
    end
  end

  describe "update_state_params/2" do
    test "updates max_frames", %{server: server} do
      :ok = OutlineServer.update_state_params(server, %{max_frames: 10})

      state = OutlineServer.get_state(server)
      assert state.max_frames == 10
    end

    test "updates threshold_percentile", %{server: server} do
      :ok = OutlineServer.update_state_params(server, %{threshold_percentile: 90})

      state = OutlineServer.get_state(server)
      assert state.threshold_percentile == 90
    end
  end

  describe "get_state/1" do
    test "returns current state", %{server: server} do
      state = OutlineServer.get_state(server)
      assert is_map(state)
      assert Map.has_key?(state, :enabled)
      assert Map.has_key?(state, :frames)
      assert Map.has_key?(state, :max_frames)
    end
  end
end
