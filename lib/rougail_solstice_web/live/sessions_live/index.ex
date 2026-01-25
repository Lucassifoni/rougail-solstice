defmodule RougailSolsticeWeb.SessionsLive.Index do
  use RougailSolsticeWeb, :live_view

  alias RougailSolstice.OpticalPieces
  alias RougailSolstice.Sessions.SessionManager
  alias RougailSolstice.Sessions.Topics

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.session_events())
    end

    {:ok,
     socket
     |> assign(:optical_pieces, OpticalPieces.list_optical_pieces())
     |> assign(:sessions, SessionManager.list_sessions())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_session", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case SessionManager.open_session(id) do
      {:ok, session_id} ->
        {:noreply,
         socket
         |> put_flash(:info, "Session opened")
         |> push_navigate(to: ~p"/sessions/#{session_id}/robot")}

      {:error, :already_open} ->
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{id}/robot")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to open session: #{inspect(reason)}")}
    end
  end

  def handle_event("close_session", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case SessionManager.close_session(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Session closed")
         |> assign(:sessions, SessionManager.list_sessions())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to close session: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:session_opened, _session_id}, socket) do
    {:noreply, assign(socket, :sessions, SessionManager.list_sessions())}
  end

  def handle_info({:session_closed, _session_id}, socket) do
    {:noreply, assign(socket, :sessions, SessionManager.list_sessions())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <h1 class="text-2xl font-bold mb-6">Sessions</h1>

      <div class="mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-xl font-semibold">Open Sessions</h2>
        </div>

        <%= if @sessions == [] do %>
          <p class="text-gray-500 italic">No active sessions</p>
        <% else %>
          <div class="space-y-2">
            <%= for session <- @sessions do %>
              <div class="flex items-center justify-between bg-green-50 border border-green-200 rounded p-3">
                <div>
                  <span class="font-medium"><%= session.optical_piece_name %></span>
                  <span class="text-sm text-gray-500 ml-2">
                    Started <%= format_time(session.started_at) %>
                  </span>
                </div>
                <div class="flex gap-2">
                  <.link
                    navigate={~p"/sessions/#{session.session_id}/robot"}
                    class="px-3 py-1 bg-blue-500 text-white rounded hover:bg-blue-600"
                  >
                    Open
                  </.link>
                  <button
                    phx-click="close_session"
                    phx-value-id={session.session_id}
                    class="px-3 py-1 bg-red-500 text-white rounded hover:bg-red-600"
                  >
                    Close
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div>
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-xl font-semibold">Optical Pieces</h2>
          <.link
            navigate={~p"/optical-pieces"}
            class="px-3 py-1 bg-gray-200 rounded hover:bg-gray-300"
          >
            Manage
          </.link>
        </div>

        <%= if @optical_pieces == [] do %>
          <p class="text-gray-500 italic">
            No optical pieces configured.
            <.link navigate={~p"/optical-pieces/new"} class="text-blue-500 underline">
              Create one
            </.link>
          </p>
        <% else %>
          <div class="space-y-2">
            <%= for op <- @optical_pieces do %>
              <div class="flex items-center justify-between bg-white border rounded p-3">
                <div>
                  <span class="font-medium"><%= op.name %></span>
                  <span class="text-sm text-gray-500 ml-2">
                    D=<%= op.diameter %>mm, RoC=<%= op.roc %>mm
                  </span>
                  <%= if op.camera_port do %>
                    <span class="text-sm text-gray-500 ml-2">
                      Camera: <%= op.camera_model || op.camera_port %>
                    </span>
                  <% end %>
                </div>
                <div class="flex gap-2">
                  <%= if session_open?(op.id, @sessions) do %>
                    <.link
                      navigate={~p"/sessions/#{op.id}/robot"}
                      class="px-3 py-1 bg-green-500 text-white rounded hover:bg-green-600"
                    >
                      Continue
                    </.link>
                  <% else %>
                    <button
                      phx-click="open_session"
                      phx-value-id={op.id}
                      class="px-3 py-1 bg-blue-500 text-white rounded hover:bg-blue-600"
                    >
                      Start Session
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp session_open?(optical_piece_id, sessions) do
    Enum.any?(sessions, &(&1.session_id == optical_piece_id))
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M")
  end
end
