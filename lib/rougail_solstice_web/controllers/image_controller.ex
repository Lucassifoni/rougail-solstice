defmodule RougailSolsticeWeb.ImageController do
  use RougailSolsticeWeb, :controller

  alias RougailSolstice.ImageStore

  def show(conn, %{"key" => key}) do
    case ImageStore.get(key) do
      %{binary: binary, content_type: content_type} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
        |> send_resp(200, binary)

      nil ->
        send_resp(conn, 404, "Not found")
    end
  end
end
