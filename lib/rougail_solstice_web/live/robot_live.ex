defmodule RougailSolsticeWeb.RobotLive do
  use RougailSolsticeWeb, :live_view

  import RougailSolsticeWeb.DetectionComponents

  alias RougailSolstice.Commands
  alias RougailSolstice.Interferometry
  alias RougailSolstice.Interferometry.Server, as: InterfServer
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
          Topics.subscribe(Topics.robot(session_id))
          Topics.subscribe(Topics.interferometry(session_id))
          Topics.subscribe(Topics.outline(session_id))
          Topics.subscribe(Topics.outline_preview(session_id))
        end

        robot_state = RobotServer.get_state(servers.robot)
        interf_state = InterfServer.get_state(servers.interferometry)
        outline_state = OutlineServer.get_state(servers.outline)
        adapters = CameraAdapter.all()
        configs = Interferometry.list_configs()

        {:ok,
         socket
         |> assign(:session_id, session_id)
         |> assign(:session_info, session_info)
         |> assign(:servers, servers)
         |> assign(:state, robot_state)
         |> assign(:interf_state, interf_state)
         |> assign(:outline_state, outline_state)
         |> assign(:adapters, adapters)
         |> assign(:configs, configs)
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
      case Commands.move_axis(socket.assigns.servers.robot, axis, delta) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("set_position", %{"axis" => axis, "position" => position}, socket) do
    axis = String.to_existing_atom(axis)
    position = String.to_integer(position)

    socket =
      case Commands.set_axis_position(socket.assigns.servers.robot, axis, position) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("lock_camera", _params, socket) do
    socket =
      case Commands.lock_camera(socket.assigns.servers.robot) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("take_picture", _params, socket) do
    socket =
      case Commands.take_picture(socket.assigns.servers.robot) do
        {:ok, _state, _capture} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("release_camera", _params, socket) do
    socket =
      case Commands.release_camera(socket.assigns.servers.robot) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("change_adapter", params, socket) do
    adapter_name = params["adapter"] || params["value"]
    adapter = CameraAdapter.get_by_name(adapter_name)

    socket =
      if adapter do
        case RobotServer.set_adapter(socket.assigns.servers.robot, adapter) do
          {:ok, _state} -> assign(socket, :error, nil)
          {:error, reason} -> assign(socket, :error, format_error(reason))
        end
      else
        assign(socket, :error, "Unknown adapter")
      end

    {:noreply, socket}
  end

  def handle_event("start_liveview", _params, socket) do
    servers = socket.assigns.servers

    socket =
      case Commands.start_liveview(servers.robot, servers.interferometry) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("stop_liveview", _params, socket) do
    servers = socket.assigns.servers
    Commands.stop_liveview(servers.robot, servers.interferometry)
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("update_outline_circle", params, socket) do
    cx = parse_number(params["cx"])
    cy = parse_number(params["cy"])
    r = parse_number(params["r"])
    Commands.set_outline_circle(socket.assigns.servers.interferometry, cx, cy, r)
    {:noreply, socket}
  end

  def handle_event("update_center_filter", %{"radius" => radius}, socket) do
    Commands.set_center_filter_radius(socket.assigns.servers.interferometry, parse_int(radius))
    {:noreply, socket}
  end

  def handle_event("select_config", %{"config_id" => ""}, socket) do
    {:noreply, assign(socket, :selected_config_id, nil)}
  end

  def handle_event("select_config", %{"config_id" => id}, socket) do
    config_id = String.to_integer(id)
    InterfServer.load_optical_config(socket.assigns.servers.interferometry, config_id)
    {:noreply, assign(socket, :selected_config_id, config_id)}
  end

  def handle_event("update_optical_params", params, socket) do
    optical_params = %{
      diameter: parse_number(params["diameter"]),
      roc: parse_number(params["roc"]),
      lambda: parse_number(params["lambda"]),
      conic: parse_number(params["conic"]),
      obstruction: parse_number(params["obstruction"] || "0")
    }

    InterfServer.set_optical_params(socket.assigns.servers.interferometry, optical_params)
    {:noreply, socket}
  end

  def handle_event("capture_full_shot", _params, socket) do
    socket =
      case Commands.capture_full_shot(socket.assigns.servers.interferometry) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("save_config", params, socket) do
    attrs = %{
      name: params["name"],
      diameter: parse_number(params["diameter"]),
      roc: parse_number(params["roc"]),
      lambda: parse_number(params["lambda"]),
      conic: parse_number(params["conic"]),
      obstruction: parse_number(params["obstruction"] || "0")
    }

    socket =
      case Interferometry.create_config(attrs) do
        {:ok, config} ->
          configs = Interferometry.list_configs()

          socket
          |> assign(:configs, configs)
          |> assign(:selected_config_id, config.id)
          |> assign(:error, nil)

        {:error, changeset} ->
          assign(socket, :error, format_changeset_error(changeset))
      end

    {:noreply, socket}
  end

  def handle_event("toggle_auto_outline", _params, socket) do
    outline_server = socket.assigns.servers.outline
    Commands.toggle_auto_outline(outline_server)
    outline_state = Commands.get_outline_state(outline_server)

    {:noreply,
     socket
     |> assign(:auto_outline_enabled, outline_state.enabled)
     |> assign(:outline_state, outline_state)}
  end

  def handle_event("update_detection_params", params, socket) do
    detection_params = %{
      edge_ray_count: parse_int(params["edge_ray_count"]),
      edge_threshold: parse_int(params["edge_threshold"]),
      canny_low: parse_int(params["canny_low"]),
      canny_high: parse_int(params["canny_high"]),
      blur_kernel_size: parse_int(params["blur_kernel_size"]),
      max_edge_dim: parse_int(params["max_edge_dim"]),
      ransac_samples: parse_int(params["ransac_samples"]),
      ransac_inlier_threshold_ratio: parse_number(params["ransac_inlier_threshold_ratio"]),
      ransac_refinement_iterations: parse_int(params["ransac_refinement_iterations"]),
      debug_save: params["debug_save"] == "true"
    }

    outline_server = socket.assigns.servers.outline
    Commands.update_detection_params(outline_server, detection_params)
    outline_state = Commands.get_outline_state(outline_server)

    {:noreply, assign(socket, :outline_state, outline_state)}
  end

  def handle_event("update_outline_state_params", params, socket) do
    state_params = %{
      max_frames: parse_int(params["max_frames"]),
      min_confidence: parse_number(params["min_confidence"]),
      threshold_percentile: parse_number(params["threshold_percentile"])
    }

    outline_server = socket.assigns.servers.outline
    Commands.update_outline_state_params(outline_server, state_params)
    outline_state = Commands.get_outline_state(outline_server)

    {:noreply, assign(socket, :outline_state, outline_state)}
  end

  def handle_event("close_session", _params, socket) do
    SessionManager.close_session(socket.assigns.session_id)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_info({:robot_state_changed, state}, socket) do
    {:noreply, assign(socket, :state, state)}
  end

  def handle_info({:interferometry_state_changed, state}, socket) do
    prev_state = socket.assigns.interf_state
    preview_changed = state.preview_frame_path != prev_state.preview_frame_path
    dft_changed = state.dft_preview_path != prev_state.dft_preview_path
    wft_changed = state.wft_preview_path != prev_state.wft_preview_path
    center_filter_changed = state.center_filter_radius != prev_state.center_filter_radius

    socket =
      socket
      |> assign(:interf_state, state)
      |> maybe_bump_version(:preview_version, preview_changed)
      |> maybe_bump_version(:dft_version, dft_changed)
      |> maybe_bump_version(:wft_version, wft_changed)
      |> maybe_push_preview_update(state, preview_changed)
      |> maybe_push_dft_update(state, dft_changed)
      |> maybe_push_wft_update(state, wft_changed)
      |> maybe_push_circle_update(state, prev_state)
      |> maybe_push_center_filter_update(state, center_filter_changed)

    {:noreply, socket}
  end

  def handle_info({:preview_edges, url}, socket) do
    src = url <> "?v=" <> Integer.to_string(System.monotonic_time())
    {:noreply, push_event(socket, "update_edges_overlay", %{src: src})}
  end

  def handle_info({:outline_state_changed, outline_state}, socket) do
    {:noreply,
     socket
     |> assign(:outline_state, outline_state)
     |> assign(:auto_outline_enabled, outline_state.enabled)}
  end

  defp maybe_bump_version(socket, key, true), do: update(socket, key, &(&1 + 1))
  defp maybe_bump_version(socket, _key, false), do: socket

  defp maybe_push_preview_update(socket, state, true) do
    push_event(socket, "update_preview_image", %{src: state.preview_frame_path})
  end

  defp maybe_push_preview_update(socket, _state, false), do: socket

  defp maybe_push_dft_update(socket, state, true) do
    push_event(socket, "update_dft_image", %{src: state.dft_preview_path})
  end

  defp maybe_push_dft_update(socket, _state, false), do: socket

  defp maybe_push_wft_update(socket, state, true) do
    push_event(socket, "update_wft_image", %{src: state.wft_preview_path})
  end

  defp maybe_push_wft_update(socket, _state, false), do: socket

  defp maybe_push_center_filter_update(socket, state, true) do
    push_event(socket, "set_center_filter", %{radius: state.center_filter_radius})
  end

  defp maybe_push_center_filter_update(socket, _state, false), do: socket

  @canvas_width 640
  @canvas_height 480

  defp maybe_push_circle_update(socket, state, prev_state) do
    if state.outline_circle != prev_state.outline_circle do
      scaled = scale_circle_for_canvas(state.outline_circle, state.preview_dimensions)
      push_event(socket, "set_circle", scaled)
    else
      socket
    end
  end

  defp scale_circle_for_canvas(circle, nil), do: circle

  defp scale_circle_for_canvas(circle, {img_w, img_h}) do
    scale_x = @canvas_width / img_w
    scale_y = @canvas_height / img_h
    scale = min(scale_x, scale_y)

    %{
      cx: circle.cx * scale,
      cy: circle.cy * scale,
      r: circle.r * scale
    }
  end

  defp format_error(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_error({:cli_error, code, output}) do
    "CLI error (#{code}): #{String.slice(output, 0, 100)}"
  end

  defp format_error(reason), do: inspect(reason)

  defp format_wft_source({:file, path}), do: path
  defp format_wft_source({:binary, _}), do: "(in-memory)"
  defp format_wft_source(_), do: ""

  defp format_changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
  end

  defp parse_number(str) when is_binary(str) do
    case Float.parse(str) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_number(num) when is_number(num), do: num
  defp parse_number(_), do: 0.0

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp parse_int(num) when is_integer(num), do: num
  defp parse_int(_), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="gamepad-controller" phx-hook="Gamepad" data-session-id={@session_id}></div>
      <div class="w-full px-6 py-6">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-2xl font-bold">{@session_info.optical_piece.name}</h1>
            <p class="text-sm text-gray-500">
              Session {@session_id} | Started: {Calendar.strftime(
                @session_info.started_at,
                "%H:%M:%S"
              )}
            </p>
          </div>
          <div class="flex gap-2">
            <.link
              navigate={~p"/"}
              class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded font-medium transition-colors"
            >
              Back to Sessions
            </.link>
            <button
              type="button"
              phx-click="close_session"
              data-confirm="Close this session?"
              class="px-4 py-2 bg-red-500 hover:bg-red-600 text-white rounded font-medium transition-colors"
            >
              Close Session
            </button>
          </div>
        </div>

        <.error_banner error={@error} />

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <.axis_controls state={@state} />
          <.camera_controls state={@state} adapters={@adapters} />
          <.optical_config_controls
            configs={@configs}
            selected_config_id={@selected_config_id}
            interf_state={@interf_state}
          />
        </div>

        <.interferometry_controls interf_state={@interf_state} />

        <div class="mt-6">
          <.detection_settings outline_state={@outline_state} />
        </div>

        <div class="mt-6 grid grid-cols-1 lg:grid-cols-3 gap-6">
          <.preview_canvas_panel
            interf_state={@interf_state}
            preview_version={@preview_version}
            auto_outline_enabled={@auto_outline_enabled}
          />
          <.dft_canvas_panel
            interf_state={@interf_state}
            dft_version={@dft_version}
          />
          <.wft_canvas_panel
            interf_state={@interf_state}
            wft_version={@wft_version}
          />
        </div>

        <.analysis_results interf_state={@interf_state} />

        <.last_capture state={@state} />
      </div>
    </Layouts.app>
    """
  end

  defp error_banner(assigns) do
    ~H"""
    <div
      :if={@error}
      class="mb-4 p-4 bg-red-100 border border-red-400 text-red-700 rounded"
      role="alert"
    >
      {@error}
    </div>
    """
  end

  attr :text, :string, required: true

  defp gamepad_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-purple-100 text-purple-700 border border-purple-200">
      {@text}
    </span>
    """
  end

  defp axis_controls(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Axis Controls</h2>

      <div class="space-y-6">
        <.axis_control axis={:x} axis_state={@state.axes.x} />
        <.axis_control axis={:y} axis_state={@state.axes.y} />
        <.axis_control axis={:z} axis_state={@state.axes.z} />
      </div>
    </div>
    """
  end

  defp axis_control(assigns) do
    gamepad_hint =
      case assigns.axis do
        :x -> "L Stick X"
        :y -> "L Stick Y"
        :z -> "ZL / ZR"
      end

    assigns = assign(assigns, :gamepad_hint, gamepad_hint)

    ~H"""
    <div class="border-b pb-4 last:border-b-0 last:pb-0">
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <span class="font-medium uppercase">{@axis}</span>
          <.gamepad_badge text={@gamepad_hint} />
        </div>
        <span class="text-sm text-gray-500">
          {@axis_state.min} - {@axis_state.max}
        </span>
      </div>

      <div class="flex items-center gap-2 mb-2">
        <button
          type="button"
          phx-click="move_axis"
          phx-value-axis={@axis}
          phx-value-delta="-100"
          class="px-3 py-1 bg-gray-200 hover:bg-gray-300 rounded text-sm"
        >
          -100
        </button>
        <button
          type="button"
          phx-click="move_axis"
          phx-value-axis={@axis}
          phx-value-delta="-10"
          class="px-3 py-1 bg-gray-200 hover:bg-gray-300 rounded text-sm"
        >
          -10
        </button>
        <span class="flex-1 text-center font-mono text-lg">
          {@axis_state.position}
        </span>
        <button
          type="button"
          phx-click="move_axis"
          phx-value-axis={@axis}
          phx-value-delta="10"
          class="px-3 py-1 bg-gray-200 hover:bg-gray-300 rounded text-sm"
        >
          +10
        </button>
        <button
          type="button"
          phx-click="move_axis"
          phx-value-axis={@axis}
          phx-value-delta="100"
          class="px-3 py-1 bg-gray-200 hover:bg-gray-300 rounded text-sm"
        >
          +100
        </button>
      </div>

      <input
        type="range"
        min={@axis_state.min}
        max={@axis_state.max}
        value={@axis_state.position}
        phx-change="set_position"
        phx-value-axis={@axis}
        name="position"
        class="w-full"
      />
    </div>
    """
  end

  defp camera_controls(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Camera Controls</h2>

      <div class="mb-4">
        <label class="block text-sm text-gray-500 mb-1">Adapter</label>
        <select
          name="adapter"
          phx-change="change_adapter"
          phx-blur="change_adapter"
          class="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
        >
          <option
            :for={adapter <- @adapters}
            value={RougailSolstice.Robot.CameraAdapter.adapter_name(adapter)}
            selected={adapter == @state.camera_adapter}
          >
            {RougailSolstice.Robot.CameraAdapter.adapter_name(adapter)}
          </option>
        </select>
      </div>

      <div class="flex items-center gap-2 mb-4">
        <span class="text-sm text-gray-500">Status:</span>
        <span class={[
          "px-2 py-1 rounded text-sm font-medium",
          if(@state.camera.status == :locked,
            do: "bg-yellow-100 text-yellow-800",
            else: "bg-green-100 text-green-800"
          )
        ]}>
          {@state.camera.status}
        </span>
      </div>

      <div class="flex gap-2">
        <button
          type="button"
          phx-click="lock_camera"
          disabled={@state.camera.status == :locked}
          class={[
            "px-4 py-2 rounded font-medium transition-colors",
            if(@state.camera.status == :locked,
              do: "bg-gray-200 text-gray-400 cursor-not-allowed",
              else: "bg-blue-500 hover:bg-blue-600 text-white"
            )
          ]}
        >
          Lock
        </button>
        <button
          type="button"
          phx-click="take_picture"
          disabled={@state.camera.status != :locked}
          class={[
            "px-4 py-2 rounded font-medium transition-colors",
            if(@state.camera.status != :locked,
              do: "bg-gray-200 text-gray-400 cursor-not-allowed",
              else: "bg-green-500 hover:bg-green-600 text-white"
            )
          ]}
        >
          Capture
        </button>
        <button
          type="button"
          phx-click="release_camera"
          disabled={@state.camera.status != :locked}
          class={[
            "px-4 py-2 rounded font-medium transition-colors",
            if(@state.camera.status != :locked,
              do: "bg-gray-200 text-gray-400 cursor-not-allowed",
              else: "bg-orange-500 hover:bg-orange-600 text-white"
            )
          ]}
        >
          Release
        </button>
      </div>
    </div>
    """
  end

  defp last_capture(assigns) do
    ~H"""
    <div :if={@state.camera.last_capture} class="mt-6 bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Last Capture</h2>

      <div class="grid grid-cols-2 gap-4 text-sm">
        <div>
          <span class="text-gray-500">Timestamp:</span>
          <span class="ml-2 font-mono">
            {Calendar.strftime(@state.camera.last_capture.timestamp, "%Y-%m-%d %H:%M:%S")}
          </span>
        </div>
        <div>
          <span class="text-gray-500">Image:</span>
          <span class="ml-2 font-mono">
            {format_capture_size(@state.camera.last_capture)}
          </span>
        </div>
        <div class="col-span-2">
          <span class="text-gray-500">Position:</span>
          <span class="ml-2 font-mono">
            X: {@state.camera.last_capture.position.x},
            Y: {@state.camera.last_capture.position.y},
            Z: {@state.camera.last_capture.position.z}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp format_capture_size(capture) do
    size_kb = div(byte_size(capture.image_binary), 1024)
    "In-memory (#{capture.content_type}, #{size_kb} KB)"
  end

  defp optical_config_controls(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Optical Configuration</h2>

      <div class="mb-4">
        <label class="block text-sm text-gray-500 mb-1">Load Config</label>
        <select
          name="config_id"
          phx-change="select_config"
          class="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
        >
          <option value="">-- Select --</option>
          <option
            :for={config <- @configs}
            value={config.id}
            selected={config.id == @selected_config_id}
          >
            {config.name}
          </option>
        </select>
      </div>

      <form phx-change="update_optical_params" class="space-y-3">
        <div class="grid grid-cols-2 gap-2">
          <div>
            <label class="block text-xs text-gray-500">Diameter (mm)</label>
            <input
              type="number"
              name="diameter"
              value={@interf_state.optical_params && @interf_state.optical_params.diameter}
              step="0.1"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500">ROC (mm)</label>
            <input
              type="number"
              name="roc"
              value={@interf_state.optical_params && @interf_state.optical_params.roc}
              step="0.1"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500">Lambda (nm)</label>
            <input
              type="number"
              name="lambda"
              value={(@interf_state.optical_params && @interf_state.optical_params.lambda) || 518}
              step="1"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500">Conic</label>
            <input
              type="number"
              name="conic"
              value={(@interf_state.optical_params && @interf_state.optical_params.conic) || -1}
              step="0.01"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
          <div class="col-span-2">
            <label class="block text-xs text-gray-500">Obstruction (0-1)</label>
            <input
              type="number"
              name="obstruction"
              value={(@interf_state.optical_params && @interf_state.optical_params.obstruction) || 0}
              step="0.01"
              min="0"
              max="0.99"
              class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
            />
          </div>
        </div>
      </form>
    </div>
    """
  end

  defp interferometry_controls(assigns) do
    ~H"""
    <div class="mt-6 bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Interferometry Controls</h2>

      <div class="flex flex-wrap items-center gap-4">
        <div class="flex items-center gap-2">
          <span class="text-sm text-gray-500">Liveview:</span>
          <span class={[
            "px-2 py-1 rounded text-sm font-medium",
            if(@interf_state.liveview_active,
              do: "bg-green-100 text-green-800",
              else: "bg-gray-100 text-gray-800"
            )
          ]}>
            {if @interf_state.liveview_active, do: "Active", else: "Stopped"}
          </span>
        </div>

        <div class="flex items-center gap-2">
          <button
            :if={not @interf_state.liveview_active}
            type="button"
            phx-click="start_liveview"
            class="px-4 py-2 bg-green-500 hover:bg-green-600 text-white rounded font-medium transition-colors"
          >
            Start Liveview
          </button>

          <button
            :if={@interf_state.liveview_active}
            type="button"
            phx-click="stop_liveview"
            class="px-4 py-2 bg-red-500 hover:bg-red-600 text-white rounded font-medium transition-colors"
          >
            Stop Liveview
          </button>
          <.gamepad_badge text="+" />
        </div>

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="capture_full_shot"
            disabled={@interf_state.optical_params == nil}
            class={[
              "px-4 py-2 rounded font-medium transition-colors",
              if(@interf_state.optical_params == nil,
                do: "bg-gray-200 text-gray-400 cursor-not-allowed",
                else: "bg-blue-500 hover:bg-blue-600 text-white"
              )
            ]}
          >
            Capture & Analyze
          </button>
          <.gamepad_badge text="A" />
        </div>
      </div>
    </div>
    """
  end

  defp preview_canvas_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <h2 class="text-lg font-semibold">Preview - Mirror Outline</h2>
          <.gamepad_badge text="D-pad: pos" />
          <.gamepad_badge text="L/R: size" />
        </div>
        <button
          type="button"
          phx-click="toggle_auto_outline"
          class={[
            "px-3 py-1.5 rounded text-sm font-medium transition-colors",
            if(@auto_outline_enabled,
              do: "bg-green-500 hover:bg-green-600 text-white",
              else: "bg-gray-200 hover:bg-gray-300 text-gray-700"
            )
          ]}
        >
          {if @auto_outline_enabled, do: "Auto-outline ON", else: "Auto-outline OFF"}
        </button>
      </div>

      <div
        id="preview-canvas-container"
        phx-hook="PreviewCanvas"
        phx-update="ignore"
        class="relative bg-gray-900 rounded"
      >
        <canvas width="640" height="480" class="w-full"></canvas>
      </div>

      <form phx-change="update_outline_circle" class="mt-4 grid grid-cols-3 gap-2">
        <div>
          <label class="block text-xs text-gray-500">Center X</label>
          <input
            type="number"
            name="cx"
            value={round(@interf_state.outline_circle.cx)}
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
        </div>
        <div>
          <label class="block text-xs text-gray-500">Center Y</label>
          <input
            type="number"
            name="cy"
            value={round(@interf_state.outline_circle.cy)}
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
        </div>
        <div>
          <label class="block text-xs text-gray-500">Radius</label>
          <input
            type="number"
            name="r"
            value={round(@interf_state.outline_circle.r)}
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
        </div>
      </form>
    </div>
    """
  end

  defp dft_canvas_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <div class="flex items-center gap-2 mb-4">
        <h2 class="text-lg font-semibold">DFT Preview - Center Filter</h2>
        <.gamepad_badge text="R Stick Y" />
      </div>

      <div
        id="dft-canvas-container"
        phx-hook="DftCanvas"
        phx-update="ignore"
        class="relative bg-gray-900 rounded"
      >
        <canvas width="640" height="640" class="w-full"></canvas>
      </div>

      <form phx-change="update_center_filter" class="mt-4">
        <div>
          <label class="block text-xs text-gray-500">Center Filter Radius (px)</label>
          <input
            type="number"
            name="radius"
            value={@interf_state.center_filter_radius}
            min="1"
            class="w-full px-2 py-1 border border-gray-300 rounded text-sm"
          />
        </div>
      </form>
    </div>
    """
  end

  defp wft_canvas_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Wavefront Map</h2>

      <div
        id="wft-canvas-container"
        phx-hook="WftCanvas"
        phx-update="ignore"
        class="relative bg-gray-900 rounded"
      >
        <canvas width="572" height="512" class="w-full"></canvas>
      </div>

      <div class="mt-4 text-xs text-gray-500">
        <span :if={@interf_state.wft_preview_path}>
          Blue = low, Red = high (waves)
        </span>
        <span :if={!@interf_state.wft_preview_path}>
          Run analysis to see wavefront
        </span>
      </div>
    </div>
    """
  end

  defp analysis_results(assigns) do
    ~H"""
    <div :if={@interf_state.last_analysis} class="mt-6 bg-white rounded-lg shadow p-6">
      <h2 class="text-lg font-semibold mb-4">Analysis Results</h2>

      <div class="grid grid-cols-3 gap-4 mb-4">
        <div class="text-center p-4 bg-blue-50 rounded">
          <div class="text-2xl font-bold text-blue-700">
            {Float.round(@interf_state.last_analysis.rms_waves, 3)}
          </div>
          <div class="text-sm text-gray-500">RMS (waves)</div>
        </div>
        <div class="text-center p-4 bg-green-50 rounded">
          <div class="text-2xl font-bold text-green-700">
            {Float.round(@interf_state.last_analysis.pv_waves, 3)}
          </div>
          <div class="text-sm text-gray-500">P-V (waves)</div>
        </div>
        <div class="text-center p-4 bg-purple-50 rounded">
          <div class="text-2xl font-bold text-purple-700">
            {Float.round(@interf_state.last_analysis.strehl, 3)}
          </div>
          <div class="text-sm text-gray-500">Strehl</div>
        </div>
      </div>

      <details class="mt-4">
        <summary class="cursor-pointer text-sm text-gray-600 hover:text-gray-900">
          Zernike Coefficients (nulled)
        </summary>
        <div class="mt-2 grid grid-cols-4 gap-2 text-xs font-mono">
          <div
            :for={{term, value} <- Enum.sort(@interf_state.last_analysis.zernikes_nulled)}
            class="flex justify-between bg-gray-50 px-2 py-1 rounded"
          >
            <span>Z{term}:</span>
            <span>{Float.round(value, 4)}</span>
          </div>
        </div>
      </details>

      <div :if={@interf_state.last_analysis.wft} class="mt-4 text-xs text-gray-500">
        Output: {format_wft_source(@interf_state.last_analysis.wft)}
      </div>
    </div>
    """
  end
end
