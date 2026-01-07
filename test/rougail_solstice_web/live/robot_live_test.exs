defmodule RougailSolsticeWeb.RobotLiveTest do
  use RougailSolsticeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RougailSolstice.Robot.Server

  setup do
    Server.reset()
    :ok
  end

  describe "mount" do
    test "renders robot control page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/robot")

      assert html =~ "Robot Control"
      assert html =~ "Axis Controls"
      assert html =~ "Camera Controls"
      assert has_element?(view, "button", "Lock")
      assert has_element?(view, "button", "Capture")
      assert has_element?(view, "button", "Release")
    end

    test "shows initial axis positions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/robot")

      assert html =~ "500"
    end
  end

  describe "axis controls" do
    test "move axis buttons update position", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/robot")

      view
      |> element("button[phx-value-axis=x][phx-value-delta='10']")
      |> render_click()

      assert render(view) =~ "510"
    end

    test "shows error for invalid move", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/robot")

      for _ <- 1..6 do
        view
        |> element("button[phx-value-axis=x][phx-value-delta='100']")
        |> render_click()
      end

      assert render(view) =~ "Above maximum"
    end
  end

  describe "camera controls" do
    test "lock camera changes status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/robot")

      view
      |> element("button", "Lock")
      |> render_click()

      assert render(view) =~ "locked"
    end

    test "capture button works when locked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/robot")

      view |> element("button", "Lock") |> render_click()
      view |> element("button", "Capture") |> render_click()

      html = render(view)
      assert html =~ "Last Capture"
      assert html =~ "preset_"
    end

    test "release returns to idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/robot")

      view |> element("button", "Lock") |> render_click()
      view |> element("button", "Release") |> render_click()

      assert render(view) =~ "idle"
    end
  end
end
