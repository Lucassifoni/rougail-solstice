defmodule RougailSolstice.Interferometry.ServerTest do
  use RougailSolstice.DataCase, async: false

  alias RougailSolstice.Interferometry
  alias RougailSolstice.Interferometry.Server
  alias RougailSolstice.Robot.Server, as: RobotServer

  setup do
    {:ok, _robot_pid} = start_supervised({RobotServer, name: :test_robot_server})

    {:ok, pid} =
      start_supervised({Server, name: :test_interf_server, robot_server: :test_robot_server})

    Server.subscribe(nil)
    %{server: pid}
  end

  describe "get_state/1" do
    test "returns initial state" do
      state = Server.get_state(:test_interf_server)
      assert state.liveview_active == false
      assert state.outline_circle == %{cx: 0, cy: 0, r: 100}
      assert state.center_filter_radius == 10
    end
  end

  describe "set_outline_circle/2" do
    test "updates circle and broadcasts" do
      {:ok, state} = Server.set_outline_circle(:test_interf_server, %{cx: 150, cy: 200, r: 120})

      assert state.outline_circle == %{cx: 150, cy: 200, r: 120}
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "set_center_filter_radius/2" do
    test "updates radius with valid value" do
      {:ok, state} = Server.set_center_filter_radius(:test_interf_server, 25)

      assert state.center_filter_radius == 25
      assert_receive {:interferometry_state_changed, ^state}
    end

    test "rejects invalid radius" do
      {:error, :invalid_radius} = Server.set_center_filter_radius(:test_interf_server, 0)
      refute_receive {:interferometry_state_changed, _}
    end
  end

  describe "set_optical_params/2" do
    test "updates optical params and broadcasts" do
      params = %{
        diameter: 203.0,
        roc: 1438.0,
        lambda: 518.0,
        conic: -1.0,
        obstruction: 0.0
      }

      {:ok, state} = Server.set_optical_params(:test_interf_server, params)

      assert state.optical_params == params
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "load_optical_config/2" do
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

      {:ok, state} = Server.load_optical_config(:test_interf_server, config.id)

      assert state.optical_params.diameter == 250.0
      assert state.optical_params.roc == 1500.0
      assert state.optical_params.lambda == 550.0
      assert state.optical_params.conic == -1.5
      assert state.optical_params.obstruction == 0.1
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "start_liveview/1" do
    test "sets liveview_active to true and broadcasts" do
      {:ok, state} = Server.start_liveview(:test_interf_server)

      assert state.liveview_active == true
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "stop_liveview/1" do
    test "sets liveview_active to false and broadcasts" do
      {:ok, _} = Server.start_liveview(:test_interf_server)
      {:ok, state} = Server.stop_liveview(:test_interf_server)

      assert state.liveview_active == false
      assert_receive {:interferometry_state_changed, _}
      assert_receive {:interferometry_state_changed, ^state}
    end
  end

  describe "reset/1" do
    test "resets to initial state and broadcasts" do
      {:ok, _} = Server.set_outline_circle(:test_interf_server, %{cx: 500, cy: 500, r: 200})
      {:ok, _} = Server.start_liveview(:test_interf_server)

      {:ok, state} = Server.reset(:test_interf_server)

      assert state.outline_circle == %{cx: 0, cy: 0, r: 100}
      assert state.liveview_active == false
      assert_receive {:interferometry_state_changed, _}
    end
  end

  describe "analysis_readiness/1" do
    test "returns {:not_ready, missing} for initial state" do
      assert {:not_ready, missing} = Server.analysis_readiness(:test_interf_server)
      assert :optical_params in missing
      assert :full_shot in missing
    end

    test "returns :ready when fully configured" do
      {:ok, _} =
        Server.set_optical_params(:test_interf_server, %{
          diameter: 203.0,
          roc: 1438.0,
          lambda: 518.0,
          conic: -1.0,
          obstruction: 0.0
        })

      {:ok, _} = Server.set_outline_circle(:test_interf_server, %{cx: 100, cy: 100, r: 80})

      assert {:not_ready, missing} = Server.analysis_readiness(:test_interf_server)
      assert :full_shot in missing
      refute :optical_params in missing
      refute :outline_circle in missing
    end
  end
end
