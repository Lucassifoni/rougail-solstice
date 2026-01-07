defmodule RougailSolstice.Robot.AxisTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Robot.Axis

  describe "new/4" do
    test "creates axis with valid bounds and default initial position" do
      assert {:ok, axis} = Axis.new(:x, 0, 1000)
      assert axis.name == :x
      assert axis.min == 0
      assert axis.max == 1000
      assert axis.position == 0
    end

    test "creates axis with custom initial position" do
      assert {:ok, axis} = Axis.new(:y, 0, 1000, 500)
      assert axis.position == 500
    end

    test "rejects invalid bounds where min > max" do
      assert {:error, :invalid_bounds} = Axis.new(:z, 100, 50)
    end

    test "rejects initial position below minimum" do
      assert {:error, :initial_out_of_bounds} = Axis.new(:x, 0, 1000, -10)
    end

    test "rejects initial position above maximum" do
      assert {:error, :initial_out_of_bounds} = Axis.new(:x, 0, 1000, 1001)
    end

    test "allows initial position at boundaries" do
      assert {:ok, axis_min} = Axis.new(:x, 0, 1000, 0)
      assert axis_min.position == 0

      assert {:ok, axis_max} = Axis.new(:x, 0, 1000, 1000)
      assert axis_max.position == 1000
    end

    test "allows negative bounds" do
      assert {:ok, axis} = Axis.new(:x, -500, 500, 0)
      assert axis.min == -500
      assert axis.max == 500
    end
  end

  describe "move/2" do
    setup do
      {:ok, axis} = Axis.new(:x, 0, 1000, 500)
      %{axis: axis}
    end

    test "moves axis by positive delta", %{axis: axis} do
      assert {:ok, moved} = Axis.move(axis, 100)
      assert moved.position == 600
    end

    test "moves axis by negative delta", %{axis: axis} do
      assert {:ok, moved} = Axis.move(axis, -100)
      assert moved.position == 400
    end

    test "moves axis to exact maximum", %{axis: axis} do
      assert {:ok, moved} = Axis.move(axis, 500)
      assert moved.position == 1000
    end

    test "moves axis to exact minimum", %{axis: axis} do
      assert {:ok, moved} = Axis.move(axis, -500)
      assert moved.position == 0
    end

    test "rejects move above maximum", %{axis: axis} do
      assert {:error, :above_maximum} = Axis.move(axis, 501)
    end

    test "rejects move below minimum", %{axis: axis} do
      assert {:error, :below_minimum} = Axis.move(axis, -501)
    end

    test "allows zero delta", %{axis: axis} do
      assert {:ok, moved} = Axis.move(axis, 0)
      assert moved.position == 500
    end
  end

  describe "set_position/2" do
    setup do
      {:ok, axis} = Axis.new(:x, 0, 1000, 500)
      %{axis: axis}
    end

    test "sets valid position", %{axis: axis} do
      assert {:ok, updated} = Axis.set_position(axis, 750)
      assert updated.position == 750
    end

    test "sets position to minimum", %{axis: axis} do
      assert {:ok, updated} = Axis.set_position(axis, 0)
      assert updated.position == 0
    end

    test "sets position to maximum", %{axis: axis} do
      assert {:ok, updated} = Axis.set_position(axis, 1000)
      assert updated.position == 1000
    end

    test "rejects position below minimum", %{axis: axis} do
      assert {:error, :below_minimum} = Axis.set_position(axis, -1)
    end

    test "rejects position above maximum", %{axis: axis} do
      assert {:error, :above_maximum} = Axis.set_position(axis, 1001)
    end
  end
end
