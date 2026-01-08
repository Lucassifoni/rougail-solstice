defmodule RougailSolstice.Commands do
  @moduledoc """
  Unified command interface for robot and interferometry control.
  This module abstracts control operations, enabling multiple input sources
  (web UI, gamepad channel) to use the same interface.

  All functions accept optional server names as the first parameter,
  defaulting to the global servers for production use.
  """

  alias RougailSolstice.Interferometry.Server, as: InterfServer
  alias RougailSolstice.Outline.Server, as: OutlineServer
  alias RougailSolstice.Robot.Server, as: RobotServer

  @type result :: {:ok, term()} | {:error, term()}

  @spec move_axis(GenServer.server(), atom(), integer()) :: result()
  def move_axis(robot_server \\ RobotServer, axis, delta)
      when axis in [:x, :y, :z] and is_integer(delta) do
    RobotServer.move_axis(robot_server, axis, delta)
  end

  @spec set_axis_position(GenServer.server(), atom(), integer()) :: result()
  def set_axis_position(robot_server \\ RobotServer, axis, position)
      when axis in [:x, :y, :z] and is_integer(position) do
    RobotServer.set_axis_position(robot_server, axis, position)
  end

  @spec lock_camera(GenServer.server()) :: result()
  def lock_camera(robot_server \\ RobotServer) do
    RobotServer.lock_camera(robot_server)
  end

  @spec release_camera(GenServer.server()) :: result()
  def release_camera(robot_server \\ RobotServer) do
    RobotServer.release_camera(robot_server)
  end

  @spec take_picture(GenServer.server()) :: {:ok, term(), term()} | {:error, term()}
  def take_picture(robot_server \\ RobotServer) do
    RobotServer.take_picture(robot_server)
  end

  @spec start_liveview(GenServer.server(), GenServer.server()) :: result()
  def start_liveview(robot_server \\ RobotServer, interf_server \\ InterfServer) do
    case RobotServer.lock_camera(robot_server) do
      {:ok, _state} ->
        InterfServer.start_liveview(interf_server)

      {:error, _} = error ->
        error
    end
  end

  @spec stop_liveview(GenServer.server(), GenServer.server()) :: result()
  def stop_liveview(robot_server \\ RobotServer, interf_server \\ InterfServer) do
    result = InterfServer.stop_liveview(interf_server)
    RobotServer.release_camera(robot_server)
    result
  end

  @spec toggle_liveview(GenServer.server(), GenServer.server()) :: result()
  def toggle_liveview(robot_server \\ RobotServer, interf_server \\ InterfServer) do
    state = InterfServer.get_state(interf_server)

    if state.liveview_active do
      stop_liveview(robot_server, interf_server)
    else
      start_liveview(robot_server, interf_server)
    end
  end

  @spec set_outline_circle(GenServer.server(), number(), number(), number()) :: result()
  def set_outline_circle(interf_server \\ InterfServer, cx, cy, r)
      when is_number(cx) and is_number(cy) and is_number(r) do
    InterfServer.set_outline_circle(interf_server, %{cx: cx, cy: cy, r: r})
  end

  @spec adjust_outline_position(GenServer.server(), number(), number()) :: result()
  def adjust_outline_position(interf_server \\ InterfServer, dx, dy)
      when is_number(dx) and is_number(dy) do
    state = InterfServer.get_state(interf_server)
    circle = state.outline_circle

    InterfServer.set_outline_circle(interf_server, %{
      cx: circle.cx + dx,
      cy: circle.cy + dy,
      r: circle.r
    })
  end

  @spec adjust_outline_radius(GenServer.server(), number()) :: result()
  def adjust_outline_radius(interf_server \\ InterfServer, delta) when is_number(delta) do
    state = InterfServer.get_state(interf_server)
    circle = state.outline_circle
    new_r = max(1, circle.r + delta)
    InterfServer.set_outline_circle(interf_server, %{cx: circle.cx, cy: circle.cy, r: new_r})
  end

  @spec set_center_filter_radius(GenServer.server(), pos_integer()) :: result()
  def set_center_filter_radius(interf_server \\ InterfServer, radius)
      when is_integer(radius) do
    InterfServer.set_center_filter_radius(interf_server, radius)
  end

  @spec adjust_center_filter_radius(GenServer.server(), integer()) :: result()
  def adjust_center_filter_radius(interf_server \\ InterfServer, delta)
      when is_integer(delta) do
    state = InterfServer.get_state(interf_server)
    new_radius = max(1, state.center_filter_radius + delta)
    InterfServer.set_center_filter_radius(interf_server, new_radius)
  end

  @spec capture_full_shot(GenServer.server()) :: result()
  def capture_full_shot(interf_server \\ InterfServer) do
    InterfServer.capture_full_shot(interf_server)
  end

  @spec enable_auto_outline(GenServer.server()) :: :ok
  def enable_auto_outline(outline_server \\ OutlineServer) do
    OutlineServer.enable(outline_server)
  end

  @spec disable_auto_outline(GenServer.server()) :: :ok
  def disable_auto_outline(outline_server \\ OutlineServer) do
    OutlineServer.disable(outline_server)
  end

  @spec auto_outline_enabled?(GenServer.server()) :: boolean()
  def auto_outline_enabled?(outline_server \\ OutlineServer) do
    OutlineServer.enabled?(outline_server)
  end

  @spec toggle_auto_outline(GenServer.server()) :: :ok
  def toggle_auto_outline(outline_server \\ OutlineServer) do
    if OutlineServer.enabled?(outline_server) do
      OutlineServer.disable(outline_server)
    else
      OutlineServer.enable(outline_server)
    end
  end

  @spec get_outline_state(GenServer.server()) :: RougailSolstice.Outline.State.t()
  def get_outline_state(outline_server \\ OutlineServer) do
    OutlineServer.get_state(outline_server)
  end

  @spec update_detection_params(GenServer.server(), map()) :: :ok
  def update_detection_params(outline_server \\ OutlineServer, params) when is_map(params) do
    OutlineServer.update_detection_params(outline_server, params)
  end

  @spec update_outline_state_params(GenServer.server(), map()) :: :ok
  def update_outline_state_params(outline_server \\ OutlineServer, params) when is_map(params) do
    OutlineServer.update_state_params(outline_server, params)
  end
end
