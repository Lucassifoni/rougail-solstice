defmodule RougailSolsticeWeb.GamepadChannel do
  @moduledoc """
  Channel for receiving gamepad control events.
  Translates gamepad input into Commands calls.
  """

  use Phoenix.Channel

  alias RougailSolstice.Commands

  @impl true
  def join("gamepad:control", _params, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("move_axis", %{"axis" => axis, "delta" => delta}, socket) do
    axis = String.to_existing_atom(axis)
    Commands.move_axis(axis, delta)
    {:noreply, socket}
  end

  def handle_in("toggle_liveview", _params, socket) do
    Commands.toggle_liveview()
    {:noreply, socket}
  end

  def handle_in("capture", _params, socket) do
    Commands.take_picture()
    {:noreply, socket}
  end

  def handle_in("adjust_outline_position", %{"dx" => dx, "dy" => dy}, socket) do
    Commands.adjust_outline_position(dx, dy)
    {:noreply, socket}
  end

  def handle_in("adjust_outline_radius", %{"delta" => delta}, socket) do
    Commands.adjust_outline_radius(delta)
    {:noreply, socket}
  end

  def handle_in("adjust_center_filter_radius", %{"delta" => delta}, socket) do
    Commands.adjust_center_filter_radius(delta)
    {:noreply, socket}
  end
end
