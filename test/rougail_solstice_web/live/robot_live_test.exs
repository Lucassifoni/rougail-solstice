defmodule RougailSolsticeWeb.RobotLiveTest do
  use RougailSolsticeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RougailSolstice.OpticalPieces
  alias RougailSolstice.Sessions.SessionManager

  setup do
    {:ok, optical_piece} =
      OpticalPieces.create_optical_piece(%{
        name: "Test Mirror #{System.unique_integer([:positive])}",
        diameter: 200.0,
        roc: 2000.0
      })

    {:ok, session_id} = SessionManager.open_session(optical_piece.id)

    on_exit(fn ->
      SessionManager.close_session(session_id)
    end)

    %{session_id: session_id, optical_piece: optical_piece}
  end

  describe "mount" do
    test "renders robot control page", %{conn: conn, session_id: session_id, optical_piece: op} do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session_id}/robot")

      assert html =~ op.name
      assert html =~ "Axis Controls"
      assert html =~ "Camera Controls"
      assert has_element?(view, "button", "Lock")
      assert has_element?(view, "button", "Capture")
      assert has_element?(view, "button", "Release")
    end

    test "shows initial axis positions", %{conn: conn, session_id: session_id} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/robot")

      assert html =~ "500"
    end

    test "redirects to home for non-existent session", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/", flash: flash}}} =
        live(conn, ~p"/sessions/999999/robot")

      assert flash["error"] =~ "Session not found"
    end
  end

  describe "axis controls" do
    test "move axis buttons update position", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/robot")

      view
      |> element("button[phx-value-axis=x][phx-value-delta='10']")
      |> render_click()

      assert render(view) =~ "510"
    end

    test "shows error for invalid move", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/robot")

      for _ <- 1..6 do
        view
        |> element("button[phx-value-axis=x][phx-value-delta='100']")
        |> render_click()
      end

      assert render(view) =~ "Above maximum"
    end
  end

  describe "camera controls" do
    test "lock camera changes status", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/robot")

      view
      |> element("button", "Lock")
      |> render_click()

      assert render(view) =~ "locked"
    end

    test "capture button works when locked", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/robot")

      view |> element("button", "Lock") |> render_click()
      view |> element("button[phx-click=take_picture]", "Capture") |> render_click()

      html = render(view)
      assert html =~ "Last Capture"
      assert html =~ "In-memory"
      assert html =~ "image/jpeg"
    end

    test "release returns to idle", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/robot")

      view |> element("button", "Lock") |> render_click()
      view |> element("button", "Release") |> render_click()

      assert render(view) =~ "idle"
    end
  end

  describe "session management" do
    test "close session button redirects to home", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/robot")

      view
      |> element("button", "Close Session")
      |> render_click()

      assert_redirect(view, "/")
    end

    test "back to sessions link navigates home", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/robot")

      assert has_element?(view, "a", "Back to Sessions")
    end
  end
end
