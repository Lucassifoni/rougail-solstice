defmodule RougailSolstice.Interferometry.ServerTest do
  use RougailSolstice.DataCase, async: false

  alias RougailSolstice.Interferometry
  alias RougailSolstice.Interferometry.Server

  setup do
    {:ok, _} = Server.reset()
    Server.subscribe()
    :ok
  end

  describe "get_state/0" do
    test "returns initial state" do
      state = Server.get_state()
      assert state.liveview_active == false
      assert state.outline_circle == %{cx: 0, cy: 0, r: 100}
      assert state.center_filter_radius == 10
    end
  end

  describe "set_outline_circle/1" do
    test "updates circle and broadcasts" do
      {:ok, state} = Server.set_outline_circle(%{cx: 150, cy: 200, r: 120})

      assert state.outline_circle == %{cx: 150, cy: 200, r: 120}
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "set_center_filter_radius/1" do
    test "updates radius with valid value" do
      {:ok, state} = Server.set_center_filter_radius(25)

      assert state.center_filter_radius == 25
      assert_receive {:interferometry_state_changed, ^state}
    end

    test "rejects invalid radius" do
      {:error, :invalid_radius} = Server.set_center_filter_radius(0)
      refute_receive {:interferometry_state_changed, _}
    end
  end

  describe "set_optical_params/1" do
    test "updates optical params and broadcasts" do
      params = %{
        diameter: 203.0,
        roc: 1438.0,
        lambda: 518.0,
        conic: -1.0,
        obstruction: 0.0
      }

      {:ok, state} = Server.set_optical_params(params)

      assert state.optical_params == params
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "load_optical_config/1" do
    test "loads config from database" do
      {:ok, config} =
        Interferometry.create_config(%{
          name: "Test Config",
          diameter: 250.0,
          roc: 1500.0,
          lambda: 550.0,
          conic: -1.5,
          obstruction: 0.1
        })

      {:ok, state} = Server.load_optical_config(config.id)

      assert state.optical_params.diameter == 250.0
      assert state.optical_params.roc == 1500.0
      assert state.optical_params.lambda == 550.0
      assert state.optical_params.conic == -1.5
      assert state.optical_params.obstruction == 0.1
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "start_liveview/0" do
    test "sets liveview_active to true and broadcasts" do
      {:ok, state} = Server.start_liveview()

      assert state.liveview_active == true
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "stop_liveview/0" do
    test "sets liveview_active to false and broadcasts" do
      {:ok, _} = Server.start_liveview()
      {:ok, state} = Server.stop_liveview()

      assert state.liveview_active == false
      assert_receive {:interferometry_state_changed, _}
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "reset/0" do
    test "resets to initial state and broadcasts" do
      {:ok, _} = Server.set_outline_circle(%{cx: 500, cy: 500, r: 200})
      {:ok, _} = Server.start_liveview()

      {:ok, state} = Server.reset()

      assert state.outline_circle == %{cx: 0, cy: 0, r: 100}
      assert state.liveview_active == false
      assert_receive {:interferometry_state_changed, _}
    end
  end
end
