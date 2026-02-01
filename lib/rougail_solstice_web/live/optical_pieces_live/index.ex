defmodule RougailSolsticeWeb.OpticalPiecesLive.Index do
  use RougailSolsticeWeb, :live_view

  alias RougailSolstice.OpticalPieces
  alias RougailSolstice.OpticalPieces.OpticalPiece
  alias RougailSolstice.Robot.CameraAdapter.Canon

  @poll_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_camera_poll()

    {:ok,
     socket
     |> assign(:optical_pieces, OpticalPieces.list_optical_pieces())
     |> assign(:detected_cameras, [])
     |> assign(:connected_ports, fetch_connected_ports())
     |> assign(:detected_serial_ports, [])}
  end

  @impl true
  def handle_info(:poll_cameras, socket) do
    schedule_camera_poll()
    {:noreply, assign(socket, :connected_ports, fetch_connected_ports())}
  end

  defp schedule_camera_poll, do: Process.send_after(self(), :poll_cameras, @poll_interval_ms)

  defp fetch_connected_ports do
    case Canon.detect_cameras() do
      {:ok, cameras} -> MapSet.new(cameras, & &1.port)
      {:error, _} -> MapSet.new()
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Optical Pieces")
    |> assign(:optical_piece, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    optical_piece = %OpticalPiece{}
    changeset = OpticalPieces.change_optical_piece(optical_piece)

    socket
    |> assign(:page_title, "New Optical Piece")
    |> assign(:optical_piece, optical_piece)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    optical_piece = OpticalPieces.get_optical_piece!(id)
    changeset = OpticalPieces.change_optical_piece(optical_piece)

    socket
    |> assign(:page_title, "Edit #{optical_piece.name}")
    |> assign(:optical_piece, optical_piece)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    optical_piece = OpticalPieces.get_optical_piece!(id)
    {:ok, _} = OpticalPieces.delete_optical_piece(optical_piece)

    {:noreply,
     socket
     |> put_flash(:info, "Optical piece deleted")
     |> assign(:optical_pieces, OpticalPieces.list_optical_pieces())}
  end

  def handle_event("detect_cameras", _params, socket) do
    case Canon.detect_cameras() do
      {:ok, cameras} ->
        {:noreply,
         socket
         |> assign(:detected_cameras, cameras)
         |> assign(:connected_ports, MapSet.new(cameras, & &1.port))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:detected_cameras, [])
         |> assign(:connected_ports, MapSet.new())}
    end
  end

  def handle_event("assign_camera", %{"port" => port, "model" => model}, socket) do
    params = %{"camera_port" => port, "camera_model" => model}

    changeset =
      socket.assigns.optical_piece
      |> OpticalPieces.change_optical_piece(Map.merge(socket.assigns.form.params || %{}, params))

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("detect_serial_ports", _params, socket) do
    ports =
      Circuits.UART.enumerate()
      |> Enum.filter(fn {name, _info} ->
        String.match?(name, ~r/(usbmodem|ttyACM|ttyUSB|usbserial)/i)
      end)
      |> Enum.map(fn {name, info} ->
        description = Map.get(info, :description, "")
        %{port: name, description: description}
      end)

    {:noreply, assign(socket, :detected_serial_ports, ports)}
  end

  def handle_event("assign_robot_port", %{"port" => port}, socket) do
    params = %{"robot_port" => port}

    changeset =
      socket.assigns.optical_piece
      |> OpticalPieces.change_optical_piece(Map.merge(socket.assigns.form.params || %{}, params))

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("validate", %{"optical_piece" => params}, socket) do
    changeset =
      socket.assigns.optical_piece
      |> OpticalPieces.change_optical_piece(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"optical_piece" => params}, socket) do
    save_optical_piece(socket, socket.assigns.live_action, params)
  end

  defp save_optical_piece(socket, :new, params) do
    case OpticalPieces.create_optical_piece(params) do
      {:ok, _optical_piece} ->
        {:noreply,
         socket
         |> put_flash(:info, "Optical piece created")
         |> push_navigate(to: ~p"/optical-pieces")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_optical_piece(socket, :edit, params) do
    case OpticalPieces.update_optical_piece(socket.assigns.optical_piece, params) do
      {:ok, _optical_piece} ->
        {:noreply,
         socket
         |> put_flash(:info, "Optical piece updated")
         |> push_navigate(to: ~p"/optical-pieces")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">{@page_title}</h1>
          <div class="flex gap-2">
            <.link
              navigate={~p"/"}
              class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded font-medium transition-colors"
            >
              Back to Sessions
            </.link>
            <.link
              :if={@live_action == :index}
              navigate={~p"/optical-pieces/new"}
              class="px-4 py-2 bg-blue-500 hover:bg-blue-600 text-white rounded font-medium transition-colors"
            >
              New Optical Piece
            </.link>
          </div>
        </div>

        <div :if={@live_action in [:new, :edit]} class="bg-white rounded-lg shadow p-6 mb-6">
          <.form_component
            form={@form}
            action={@live_action}
            detected_cameras={@detected_cameras}
            detected_serial_ports={@detected_serial_ports}
          />
        </div>

        <div :if={@live_action == :index} class="space-y-2">
          <div
            :for={op <- @optical_pieces}
            class="flex items-center justify-between bg-white rounded-lg shadow p-4"
          >
            <div>
              <div class="font-medium text-lg">{op.name}</div>
              <div class="text-sm text-gray-600">
                Diameter: {op.diameter}mm | RoC: {op.roc}mm | λ: {op.lambda}nm
              </div>
              <div class="text-sm text-gray-600">
                Conic: {op.conic} | Obstruction: {Float.round(op.obstruction * 100, 1)}%
              </div>
              <div :if={op.camera_port} class="text-sm text-gray-600 flex items-center gap-1.5">
                <span class={[
                  "inline-block w-2 h-2 rounded-full",
                  if(MapSet.member?(@connected_ports, op.camera_port),
                    do: "bg-green-500",
                    else: "bg-red-500"
                  )
                ]} /> Camera: {op.camera_model || "Unknown"} @ {op.camera_port}
                <span
                  :if={!MapSet.member?(@connected_ports, op.camera_port)}
                  class="text-red-500 text-xs"
                >
                  (disconnected)
                </span>
              </div>
              <div :if={!op.camera_port} class="text-sm text-gray-400 italic">No camera assigned</div>
              <div :if={op.robot_port} class="text-sm text-gray-600">
                Robot: {op.robot_port}
              </div>
              <div :if={op.notes} class="text-sm text-gray-500 mt-1">{op.notes}</div>
            </div>
            <div class="flex gap-2">
              <.link
                navigate={~p"/optical-pieces/#{op.id}/edit"}
                class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded font-medium transition-colors"
              >
                Edit
              </.link>
              <button
                type="button"
                phx-click="delete"
                phx-value-id={op.id}
                data-confirm="Are you sure you want to delete this optical piece?"
                class="px-4 py-2 bg-red-500 hover:bg-red-600 text-white rounded font-medium transition-colors"
              >
                Delete
              </button>
            </div>
          </div>

          <p :if={@optical_pieces == []} class="text-gray-500 italic text-center py-8">
            No optical pieces configured yet.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp form_component(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
      <div>
        <label class="block text-sm font-medium mb-1">Name</label>
        <.input type="text" field={@form[:name]} required />
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="block text-sm font-medium mb-1">Diameter (mm)</label>
          <.input type="number" field={@form[:diameter]} step="0.1" required />
        </div>
        <div>
          <label class="block text-sm font-medium mb-1">Radius of Curvature (mm)</label>
          <.input type="number" field={@form[:roc]} step="0.1" required />
        </div>
      </div>

      <div class="grid grid-cols-3 gap-4">
        <div>
          <label class="block text-sm font-medium mb-1">Wavelength (nm)</label>
          <.input type="number" field={@form[:lambda]} step="0.1" />
        </div>
        <div>
          <label class="block text-sm font-medium mb-1">Conic</label>
          <.input type="number" field={@form[:conic]} step="0.01" />
        </div>
        <div>
          <label class="block text-sm font-medium mb-1">Obstruction (0-1)</label>
          <.input type="number" field={@form[:obstruction]} step="0.01" />
        </div>
      </div>

      <div class="border-t pt-4 mt-4">
        <div class="flex justify-between items-center mb-2">
          <h3 class="font-medium">Camera Assignment</h3>
          <button
            type="button"
            phx-click="detect_cameras"
            class="px-3 py-1.5 bg-gray-200 hover:bg-gray-300 rounded text-sm font-medium transition-colors"
          >
            Detect Cameras
          </button>
        </div>

        <div :if={@detected_cameras != []} class="mb-2 text-sm text-gray-600">
          Detected cameras (click to assign):
          <ul class="list-disc ml-4">
            <li
              :for={cam <- @detected_cameras}
              phx-click="assign_camera"
              phx-value-port={cam.port}
              phx-value-model={cam.model}
              class="cursor-pointer hover:text-blue-600 hover:underline"
            >
              {cam.model} @ {cam.port}
            </li>
          </ul>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="block text-sm font-medium mb-1">Camera Port (e.g. usb:001,006)</label>
            <.input type="text" field={@form[:camera_port]} />
          </div>
          <div>
            <label class="block text-sm font-medium mb-1">Camera Model</label>
            <.input type="text" field={@form[:camera_model]} />
          </div>
        </div>
      </div>

      <div class="border-t pt-4 mt-4">
        <div class="flex justify-between items-center mb-2">
          <h3 class="font-medium">Robot Serial Port</h3>
          <button
            type="button"
            phx-click="detect_serial_ports"
            class="px-3 py-1.5 bg-gray-200 hover:bg-gray-300 rounded text-sm font-medium transition-colors"
          >
            Detect Ports
          </button>
        </div>

        <div :if={@detected_serial_ports != []} class="mb-2 text-sm text-gray-600">
          Detected serial ports (click to assign):
          <ul class="list-disc ml-4">
            <li
              :for={p <- @detected_serial_ports}
              phx-click="assign_robot_port"
              phx-value-port={p.port}
              class="cursor-pointer hover:text-blue-600 hover:underline"
            >
              {p.port}
              <span :if={p.description != ""} class="text-gray-400">
                ({p.description})
              </span>
            </li>
          </ul>
        </div>

        <div :if={@detected_serial_ports == []} class="mb-2 text-sm text-gray-400 italic">
          No Arduino-like serial ports detected. Click "Detect Ports" to scan.
        </div>

        <div>
          <label class="block text-sm font-medium mb-1">
            Robot Port (e.g. /dev/tty.usbmodem14101)
          </label>
          <.input type="text" field={@form[:robot_port]} />
        </div>
      </div>

      <div>
        <label class="block text-sm font-medium mb-1">Notes</label>
        <.input type="textarea" field={@form[:notes]} />
      </div>

      <div class="flex gap-2 pt-4">
        <button
          type="submit"
          class="px-4 py-2 bg-blue-500 hover:bg-blue-600 text-white rounded font-medium transition-colors"
        >
          Save
        </button>
        <.link
          navigate={~p"/optical-pieces"}
          class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded font-medium transition-colors"
        >
          Cancel
        </.link>
      </div>
    </.form>
    """
  end
end
