defmodule RougailSolsticeWeb.PageControllerTest do
  use RougailSolsticeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Sessions"
  end
end
