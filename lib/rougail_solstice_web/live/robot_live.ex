defmodule RougailSolsticeWeb.RobotLive do
  use RougailSolsticeWeb, :live_view

  alias RougailSolstice.Commands
  alias RougailSolstice.Interferometry
  alias RougailSolstice.Interferometry.Server, as: InterfServer
  alias RougailSolstice.Robot.CameraAdapter
  alias RougailSolstice.Robot.Server

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Server.subscribe()
      InterfServer.subscribe()
    end

    state = Server.get_state()
    interf_state = InterfServer.get_state()
    adapters = CameraAdapter.all()
    configs = Interferometry.list_configs()

    {:ok,
     socket
     |> assign(:state, state)
     |> assign(:interf_state, interf_state)
     |> assign(:adapters, adapters)
     |> assign(:configs, configs)
     |> assign(:selected_config_id, nil)
     |> assign(:preview_version, 0)
     |> assign(:dft_version, 0)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("move_axis", %{"axis" => axis, "delta" => delta}, socket) do
    axis = String.to_existing_atom(axis)
    delta = String.to_integer(delta)

    socket =
      case Commands.move_axis(axis, delta) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("set_position", %{"axis" => axis, "position" => position}, socket) do
    axis = String.to_existing_atom(axis)
    position = String.to_integer(position)

    socket =
      case Commands.set_axis_position(axis, position) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("lock_camera", _params, socket) do
    socket =
      case Commands.lock_camera() do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("take_picture", _params, socket) do
    socket =
      case Commands.take_picture() do
        {:ok, _state, _capture} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("release_camera", _params, socket) do
    socket =
      case Commands.release_camera() do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("change_adapter", %{"adapter" => adapter_name}, socket) do
    adapter = CameraAdapter.get_by_name(adapter_name)

    socket =
      if adapter do
        case Server.set_adapter(adapter) do
          {:ok, _state} -> assign(socket, :error, nil)
          {:error, reason} -> assign(socket, :error, format_error(reason))
        end
      else
        assign(socket, :error, "Unknown adapter")
      end

    {:noreply, socket}
  end

  def handle_event("start_liveview", _params, socket) do
    socket =
      case Commands.start_liveview() do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("stop_liveview", _params, socket) do
    Commands.stop_liveview()
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("update_outline_circle", params, socket) do
    cx = parse_number(params["cx"])
    cy = parse_number(params["cy"])
    r = parse_number(params["r"])
    Commands.set_outline_circle(cx, cy, r)
    {:noreply, socket}
  end

  def handle_event("update_center_filter", %{"radius" => radius}, socket) do
    Commands.set_center_filter_radius(parse_int(radius))
    {:noreply, socket}
  end

  def handle_event("select_config", %{"config_id" => ""}, socket) do
    {:noreply, assign(socket, :selected_config_id, nil)}
  end

  def handle_event("select_config", %{"config_id" => id}, socket) do
    config_id = String.to_integer(id)
    InterfServer.load_optical_config(config_id)
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

    InterfServer.set_optical_params(optical_params)
    {:noreply, socket}
  end

  def handle_event("capture_full_shot", _params, socket) do
    socket =
      case Commands.capture_full_shot() do
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

  @impl true
  def handle_info({:robot_state_changed, state}, socket) do
    {:noreply, assign(socket, :state, state)}
  end

  def handle_info({:interferometry_state_changed, state}, socket) do
    socket =
      socket
      |> assign(:interf_state, state)
      |> maybe_bump_preview_version(state)
      |> maybe_bump_dft_version(state)

    {:noreply, socket}
  end

  defp maybe_bump_preview_version(socket, state) do
    if state.preview_frame_path != socket.assigns.interf_state.preview_frame_path do
      update(socket, :preview_version, &(&1 + 1))
    else
      socket
    end
  end

  defp maybe_bump_dft_version(socket, state) do
    if state.dft_preview_path != socket.assigns.interf_state.dft_preview_path do
      update(socket, :dft_version, &(&1 + 1))
    else
      socket
    end
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
      <div id="gamepad-controller" phx-hook="Gamepad"></div>
      <div class="w-full px-6 py-6">
        <h1 class="text-2xl font-bold mb-6">Robot Control</h1>

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

        <div class="mt-6 grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.preview_canvas_panel
            interf_state={@interf_state}
            preview_version={@preview_version}
          />
          <.dft_canvas_panel
            interf_state={@interf_state}
            dft_version={@dft_version}
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
          <span class="ml-2 font-mono">{@state.camera.last_capture.image_path}</span>
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
      <div class="flex items-center gap-2 mb-4">
        <h2 class="text-lg font-semibold">Preview - Mirror Outline</h2>
        <.gamepad_badge text="D-pad: pos" />
        <.gamepad_badge text="L/R: size" />
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

      <script :if={@interf_state.preview_frame_path}>
        window.liveSocket && window.liveSocket.execJS(
          document.getElementById("preview-canvas-container"),
          JSON.stringify([["push", {event: "update_preview_image", value: {src: "<%= @interf_state.preview_frame_path %>?v=<%= @preview_version %>"}}]])
        )
      </script>
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

      <script :if={@interf_state.dft_preview_path}>
        window.liveSocket && window.liveSocket.execJS(
          document.getElementById("dft-canvas-container"),
          JSON.stringify([["push", {event: "update_dft_image", value: {src: "<%= @interf_state.dft_preview_path %>?v=<%= @dft_version %>"}}]])
        )
      </script>
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

      <div :if={@interf_state.last_analysis.wft_path} class="mt-4 text-xs text-gray-500">
        Output: {@interf_state.last_analysis.wft_path}
      </div>
    </div>
    """
  end
end
