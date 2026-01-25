defmodule RougailSolsticeWeb.GamepadChannel do
  @moduledoc """
  Channel for receiving gamepad control events.
  Translates gamepad input into Commands calls for a specific session.
  """

  use Phoenix.Channel

  alias RougailSolstice.Commands
  alias RougailSolstice.Sessions.SessionManager

  @impl true
  def join("gamepad:control:" <> session_id_str, _params, socket) do
    session_id = String.to_integer(session_id_str)

    case SessionManager.session_servers(session_id) do
      nil ->
        {:error, %{reason: "session_not_found"}}

      servers ->
        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:servers, servers)

        {:ok, socket}
    end
  end

  @impl true
  def handle_in("move_axis", %{"axis" => axis, "delta" => delta}, socket) do
    axis = String.to_existing_atom(axis)
    Commands.move_axis(socket.assigns.servers.robot, axis, delta)
    {:noreply, socket}
  end

  def handle_in("toggle_liveview", _params, socket) do
    servers = socket.assigns.servers
    Commands.toggle_liveview(servers.robot, servers.interferometry)
    {:noreply, socket}
  end

  def handle_in("capture", _params, socket) do
    Commands.capture_full_shot(socket.assigns.servers.interferometry)
    {:noreply, socket}
  end

  def handle_in("adjust_outline_position", %{"dx" => dx, "dy" => dy}, socket) do
    Commands.adjust_outline_position(socket.assigns.servers.interferometry, dx, dy)
    {:noreply, socket}
  end

  def handle_in("adjust_outline_radius", %{"delta" => delta}, socket) do
    Commands.adjust_outline_radius(socket.assigns.servers.interferometry, delta)
    {:noreply, socket}
  end

  def handle_in("adjust_center_filter_radius", %{"delta" => delta}, socket) do
    Commands.adjust_center_filter_radius(socket.assigns.servers.interferometry, delta)
    {:noreply, socket}
  end
end
