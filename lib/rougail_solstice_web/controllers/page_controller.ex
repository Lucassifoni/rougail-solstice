defmodule RougailSolsticeWeb.PageController do
  use RougailSolsticeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
