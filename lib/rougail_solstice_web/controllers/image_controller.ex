defmodule RougailSolsticeWeb.ImageController do
  use RougailSolsticeWeb, :controller

  alias RougailSolstice.ImageStore
  alias RougailSolstice.Sessions.SessionManager
  alias RougailSolstice.Sessions.SessionSupervisor

  def show_session(conn, %{"session_id" => session_id_str, "key" => key}) do
    session_id = String.to_integer(session_id_str)

    if SessionManager.session_open?(session_id) do
      image_store = SessionSupervisor.get_server(session_id, :image_store)

      case ImageStore.get(image_store, key) do
        %{binary: binary, content_type: content_type} ->
          conn
          |> put_resp_content_type(content_type)
          |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
          |> send_resp(200, binary)

        nil ->
          send_resp(conn, 404, "Not found")
      end
    else
      send_resp(conn, 404, "Session not found")
    end
  end
end
