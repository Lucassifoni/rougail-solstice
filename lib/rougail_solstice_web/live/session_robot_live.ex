defmodule RougailSolsticeWeb.SessionRobotLive do
  @moduledoc """
  Session-aware robot control LiveView.
  Uses session-scoped servers instead of singletons.
  """

  use RougailSolsticeWeb, :live_view

  alias RougailSolstice.Interferometry.Server, as: InterfServer
  alias RougailSolstice.OpticalPieces
  alias RougailSolstice.Outline.Server, as: OutlineServer
  alias RougailSolstice.Robot.CameraAdapter
  alias RougailSolstice.Robot.Server, as: RobotServer
  alias RougailSolstice.Sessions.SessionManager
  alias RougailSolstice.Sessions.Topics

  @impl true
  def mount(%{"session_id" => session_id_str}, _session, socket) do
    session_id = String.to_integer(session_id_str)

    case SessionManager.get_session(session_id) do
      {:ok, session_info} ->
        servers = SessionManager.session_servers(session_id)

        if connected?(socket) do
          require Logger
          robot_topic = Topics.robot(session_id)
          interf_topic = Topics.interferometry(session_id)
          Logger.debug("[SessionRobotLive] subscribing to robot: #{robot_topic}, interf: #{interf_topic}")
          Topics.subscribe(robot_topic)
          Topics.subscribe(interf_topic)
        end

        robot_state = RobotServer.get_state(servers.robot)
        interf_state = InterfServer.get_state(servers.interferometry)
        outline_state = OutlineServer.get_state(servers.outline)
        adapters = CameraAdapter.all()
        optical_pieces = OpticalPieces.list_optical_pieces()

        {:ok,
         socket
         |> assign(:session_id, session_id)
         |> assign(:session_info, session_info)
         |> assign(:servers, servers)
         |> assign(:state, robot_state)
         |> assign(:interf_state, interf_state)
         |> assign(:outline_state, outline_state)
         |> assign(:adapters, adapters)
         |> assign(:optical_pieces, optical_pieces)
         |> assign(:selected_config_id, session_info.optical_piece.id)
         |> assign(:preview_version, 0)
         |> assign(:dft_version, 0)
         |> assign(:wft_version, 0)
         |> assign(:auto_outline_enabled, outline_state.enabled)
         |> assign(:error, nil)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Session not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("move_axis", %{"axis" => axis, "delta" => delta}, socket) do
    axis = String.to_existing_atom(axis)
    delta = String.to_integer(delta)

    socket =
      case RobotServer.move_axis(socket.assigns.servers.robot, axis, delta) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("set_position", %{"axis" => axis, "position" => position}, socket) do
    axis = String.to_existing_atom(axis)
    position = String.to_integer(position)

    socket =
      case RobotServer.set_axis_position(socket.assigns.servers.robot, axis, position) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("lock_camera", _params, socket) do
    socket =
      case RobotServer.lock_camera(socket.assigns.servers.robot) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("take_picture", _params, socket) do
    socket =
      case RobotServer.take_picture(socket.assigns.servers.robot) do
        {:ok, _state, _capture} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("release_camera", _params, socket) do
    socket =
      case RobotServer.release_camera(socket.assigns.servers.robot) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("change_adapter", %{"adapter" => adapter_name}, socket) do
    adapter = CameraAdapter.get_by_name(adapter_name)

    socket =
      case RobotServer.set_adapter(socket.assigns.servers.robot, adapter) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("start_liveview", _params, socket) do
    InterfServer.start_liveview(socket.assigns.servers.interferometry)
    {:noreply, socket}
  end

  def handle_event("stop_liveview", _params, socket) do
    InterfServer.stop_liveview(socket.assigns.servers.interferometry)
    {:noreply, socket}
  end

  def handle_event("update_outline_circle", params, socket) do
    cx = parse_float(params["cx"])
    cy = parse_float(params["cy"])
    r = parse_float(params["r"])

    circle = %{cx: cx, cy: cy, r: r}
    InterfServer.set_outline_circle(socket.assigns.servers.interferometry, circle)
    {:noreply, socket}
  end

  def handle_event("update_center_filter", %{"radius" => radius_str}, socket) do
    radius = String.to_integer(radius_str)
    InterfServer.set_center_filter_radius(socket.assigns.servers.interferometry, radius)
    {:noreply, socket}
  end

  def handle_event("capture_full_shot", _params, socket) do
    socket =
      case InterfServer.capture_full_shot(socket.assigns.servers.interferometry) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("toggle_auto_outline", _params, socket) do
    server = socket.assigns.servers.outline

    if socket.assigns.auto_outline_enabled do
      OutlineServer.disable(server)
    else
      OutlineServer.enable(server)
    end

    {:noreply, assign(socket, :auto_outline_enabled, !socket.assigns.auto_outline_enabled)}
  end

  def handle_event("update_detection_params", params, socket) do
    detection_params =
      params
      |> Enum.filter(fn {k, _v} -> k in ~w(canny_low canny_high ransac_threshold min_radius max_radius) end)
      |> Enum.map(fn {k, v} -> {String.to_atom(k), parse_int_or_float(v)} end)
      |> Enum.into(%{})

    OutlineServer.update_detection_params(socket.assigns.servers.outline, detection_params)
    {:noreply, socket}
  end

  def handle_event("close_session", _params, socket) do
    SessionManager.close_session(socket.assigns.session_id)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_info({:robot_state_changed, state}, socket) do
    {:noreply, assign(socket, :state, state)}
  end

  def handle_info({:interferometry_state_changed, interf_state}, socket) do
    old_interf_state = socket.assigns.interf_state

    require Logger
    Logger.debug("[SessionRobotLive] interferometry_state_changed received, liveview_active: #{interf_state.liveview_active}, preview: #{interf_state.preview_frame_path}")

    socket =
      socket
      |> assign(:interf_state, interf_state)
      |> maybe_update_preview_version(old_interf_state, interf_state)
      |> maybe_update_dft_version(old_interf_state, interf_state)
      |> maybe_update_wft_version(old_interf_state, interf_state)
      |> maybe_push_image_update(interf_state)

    {:noreply, socket}
  end

  defp maybe_update_preview_version(socket, old_state, new_state) do
    if new_state.preview_frame_path != old_state.preview_frame_path do
      assign(socket, :preview_version, socket.assigns.preview_version + 1)
    else
      socket
    end
  end

  defp maybe_update_dft_version(socket, old_state, new_state) do
    if new_state.dft_preview_path != old_state.dft_preview_path do
      assign(socket, :dft_version, socket.assigns.dft_version + 1)
    else
      socket
    end
  end

  defp maybe_update_wft_version(socket, old_state, new_state) do
    if new_state.wft_preview_path != old_state.wft_preview_path do
      assign(socket, :wft_version, socket.assigns.wft_version + 1)
    else
      socket
    end
  end

  defp maybe_push_image_update(socket, interf_state) do
    if interf_state.preview_frame_path do
      push_event(socket, "update_preview_image", %{src: interf_state.preview_frame_path})
    else
      socket
    end
  end

  defp format_error(:above_maximum), do: "Above maximum position"
  defp format_error(:below_minimum), do: "Below minimum position"
  defp format_error(:already_locked), do: "Camera already locked"
  defp format_error(:not_locked), do: "Camera not locked"
  defp format_error(reason), do: inspect(reason)

  defp parse_float(str) when is_binary(str) do
    {f, _} = Float.parse(str)
    f
  end

  defp parse_int_or_float(str) do
    case Integer.parse(str) do
      {i, ""} -> i
      _ ->
        case Float.parse(str) do
          {f, _} -> f
          :error -> 0
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4">
      <div class="flex justify-between items-center mb-4">
        <div>
          <h1 class="text-2xl font-bold">Session: <%= @session_info.optical_piece.name %></h1>
          <p class="text-sm text-gray-500">
            Session ID: <%= @session_id %> | Started: <%= Calendar.strftime(@session_info.started_at, "%H:%M:%S") %>
          </p>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/"} class="px-3 py-1 bg-gray-200 rounded hover:bg-gray-300">
            Back to Sessions
          </.link>
          <button
            phx-click="close_session"
            class="px-3 py-1 bg-red-500 text-white rounded hover:bg-red-600"
            data-confirm="Close this session?"
          >
            Close Session
          </button>
        </div>
      </div>

      <%= if @error do %>
        <div class="bg-red-100 border border-red-400 text-red-700 px-4 py-2 rounded mb-4">
          <%= @error %>
        </div>
      <% end %>

      <div class="grid grid-cols-12 gap-4">
        <div class="col-span-3 space-y-4">
          <.axis_controls state={@state} />
          <.camera_controls state={@state} adapters={@adapters} />
          <.interferometry_controls interf_state={@interf_state} auto_outline_enabled={@auto_outline_enabled} />
        </div>

        <div class="col-span-6">
          <.preview_panel
            interf_state={@interf_state}
            preview_version={@preview_version}
            auto_outline_enabled={@auto_outline_enabled}
          />
        </div>

        <div class="col-span-3 space-y-4">
          <.dft_panel interf_state={@interf_state} dft_version={@dft_version} />
          <.wft_panel interf_state={@interf_state} wft_version={@wft_version} />
          <.analysis_results interf_state={@interf_state} />
        </div>
      </div>
    </div>
    """
  end

  defp axis_controls(assigns) do
    ~H"""
    <div class="bg-white border rounded p-4">
      <h2 class="font-bold mb-2">Axis Controls</h2>
      <%= for axis <- [:x, :y, :z] do %>
        <div class="mb-2">
          <div class="flex justify-between items-center mb-1">
            <span class="font-medium uppercase"><%= axis %></span>
            <span><%= @state.axes[axis].position %></span>
          </div>
          <div class="flex gap-1">
            <button
              phx-click="move_axis"
              phx-value-axis={axis}
              phx-value-delta="-100"
              class="px-2 py-1 bg-gray-200 rounded hover:bg-gray-300"
            >
              -100
            </button>
            <button
              phx-click="move_axis"
              phx-value-axis={axis}
              phx-value-delta="-10"
              class="px-2 py-1 bg-gray-200 rounded hover:bg-gray-300"
            >
              -10
            </button>
            <button
              phx-click="move_axis"
              phx-value-axis={axis}
              phx-value-delta="10"
              class="px-2 py-1 bg-gray-200 rounded hover:bg-gray-300"
            >
              +10
            </button>
            <button
              phx-click="move_axis"
              phx-value-axis={axis}
              phx-value-delta="100"
              class="px-2 py-1 bg-gray-200 rounded hover:bg-gray-300"
            >
              +100
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp camera_controls(assigns) do
    ~H"""
    <div class="bg-white border rounded p-4">
      <h2 class="font-bold mb-2">Camera Controls</h2>
      <div class="mb-2">
        <span class="text-sm">Status: </span>
        <span class={"font-medium " <> status_color(@state.camera.status)}>
          <%= @state.camera.status %>
        </span>
      </div>
      <div class="flex gap-2 mb-2">
        <button phx-click="lock_camera" class="px-3 py-1 bg-blue-500 text-white rounded hover:bg-blue-600">
          Lock
        </button>
        <button phx-click="take_picture" class="px-3 py-1 bg-green-500 text-white rounded hover:bg-green-600">
          Capture
        </button>
        <button phx-click="release_camera" class="px-3 py-1 bg-gray-500 text-white rounded hover:bg-gray-600">
          Release
        </button>
      </div>
      <div class="text-sm">
        Adapter: <%= CameraAdapter.adapter_name(@state.camera_adapter) %>
      </div>
    </div>
    """
  end

  defp interferometry_controls(assigns) do
    ~H"""
    <div class="bg-white border rounded p-4">
      <h2 class="font-bold mb-2">Interferometry</h2>
      <div class="flex gap-2 mb-2">
        <%= if @interf_state.liveview_active do %>
          <button phx-click="stop_liveview" class="px-3 py-1 bg-red-500 text-white rounded hover:bg-red-600">
            Stop Preview
          </button>
        <% else %>
          <button phx-click="start_liveview" class="px-3 py-1 bg-green-500 text-white rounded hover:bg-green-600">
            Start Preview
          </button>
        <% end %>
        <button phx-click="capture_full_shot" class="px-3 py-1 bg-blue-500 text-white rounded hover:bg-blue-600">
          Analyze
        </button>
      </div>
      <div class="flex items-center gap-2">
        <input
          type="checkbox"
          id="auto-outline"
          checked={@auto_outline_enabled}
          phx-click="toggle_auto_outline"
        />
        <label for="auto-outline" class="text-sm">Auto-detect outline</label>
      </div>
    </div>
    """
  end

  defp preview_panel(assigns) do
    ~H"""
    <div class="bg-white border rounded p-4">
      <h2 class="font-bold mb-2">Preview</h2>
      <div
        id="preview-canvas"
        phx-hook="PreviewCanvas"
        class="relative bg-gray-900"
        style="width: 640px; height: 480px;"
        data-preview-url={@interf_state.preview_frame_path}
        data-circle-cx={@interf_state.outline_circle && @interf_state.outline_circle.cx}
        data-circle-cy={@interf_state.outline_circle && @interf_state.outline_circle.cy}
        data-circle-r={@interf_state.outline_circle && @interf_state.outline_circle.r}
      >
        <canvas width="640" height="480" class="w-full h-full"></canvas>
        <%= if !@interf_state.preview_frame_path do %>
          <div class="absolute inset-0 flex items-center justify-center text-gray-500 pointer-events-none">
            No preview - start liveview
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp dft_panel(assigns) do
    ~H"""
    <div class="bg-white border rounded p-4">
      <h2 class="font-bold mb-2">DFT Preview</h2>
      <%= if @interf_state.dft_preview_path do %>
        <img
          src={"#{@interf_state.dft_preview_path}?v=#{@dft_version}"}
          class="w-full"
          alt="DFT"
        />
      <% else %>
        <div class="bg-gray-200 h-32 flex items-center justify-center text-gray-500 text-sm">
          No DFT available
        </div>
      <% end %>
    </div>
    """
  end

  defp wft_panel(assigns) do
    ~H"""
    <div class="bg-white border rounded p-4">
      <h2 class="font-bold mb-2">Wavefront</h2>
      <%= if @interf_state.wft_preview_path do %>
        <img
          src={"#{@interf_state.wft_preview_path}?v=#{@wft_version}"}
          class="w-full"
          alt="Wavefront"
        />
      <% else %>
        <div class="bg-gray-200 h-32 flex items-center justify-center text-gray-500 text-sm">
          No wavefront available
        </div>
      <% end %>
    </div>
    """
  end

  defp analysis_results(assigns) do
    ~H"""
    <div class="bg-white border rounded p-4">
      <h2 class="font-bold mb-2">Analysis Results</h2>
      <%= if @interf_state.last_analysis do %>
        <div class="space-y-1 text-sm">
          <div>RMS: <%= Float.round(@interf_state.last_analysis.rms_waves, 4) %> waves</div>
          <div>P-V: <%= Float.round(@interf_state.last_analysis.pv_waves, 3) %> waves</div>
          <div>Strehl: <%= Float.round(@interf_state.last_analysis.strehl * 100, 1) %>%</div>
        </div>
      <% else %>
        <div class="text-gray-500 text-sm">No analysis yet</div>
      <% end %>
    </div>
    """
  end

  defp status_color(:idle), do: "text-gray-600"
  defp status_color(:locked), do: "text-blue-600"
  defp status_color(:capturing), do: "text-green-600"
  defp status_color(_), do: "text-gray-600"
end
