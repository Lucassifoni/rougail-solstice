defmodule RougailSolsticeWeb.RobotLive do
  use RougailSolsticeWeb, :live_view

  alias RougailSolstice.Robot.CameraAdapter
  alias RougailSolstice.Robot.Server

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Server.subscribe()
    end

    state = Server.get_state()
    adapters = CameraAdapter.all()

    {:ok,
     socket
     |> assign(:state, state)
     |> assign(:adapters, adapters)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("move_axis", %{"axis" => axis, "delta" => delta}, socket) do
    axis = String.to_existing_atom(axis)
    delta = String.to_integer(delta)

    socket =
      case Server.move_axis(axis, delta) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("set_position", %{"axis" => axis, "position" => position}, socket) do
    axis = String.to_existing_atom(axis)
    position = String.to_integer(position)

    socket =
      case Server.set_axis_position(axis, position) do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("lock_camera", _params, socket) do
    socket =
      case Server.lock_camera() do
        {:ok, _state} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("take_picture", _params, socket) do
    socket =
      case Server.take_picture() do
        {:ok, _state, _capture} -> assign(socket, :error, nil)
        {:error, reason} -> assign(socket, :error, format_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("release_camera", _params, socket) do
    socket =
      case Server.release_camera() do
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

  @impl true
  def handle_info({:robot_state_changed, state}, socket) do
    {:noreply, assign(socket, :state, state)}
  end

  defp format_error(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto p-6">
        <h1 class="text-2xl font-bold mb-6">Robot Control</h1>

        <.error_banner error={@error} />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <.axis_controls state={@state} />
          <.camera_controls state={@state} adapters={@adapters} />
        </div>

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
    ~H"""
    <div class="border-b pb-4 last:border-b-0 last:pb-0">
      <div class="flex items-center justify-between mb-2">
        <span class="font-medium uppercase">{@axis}</span>
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
end
