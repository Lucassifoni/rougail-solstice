defmodule RougailSolstice.Robot.Motor.ProgramTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Robot.Motor.Program

  describe "parse/1" do
    test "parses a complete program" do
      text = """
      X speed 50
      X positive
      X step 10
      sleep 300
      X negative
      X step 20
      stop
      """

      assert {:ok, instructions} = Program.parse(text)

      assert instructions == [
               {:set_speed, :axis1, 50},
               {:set_direction, :axis1, :positive},
               {:step, :axis1, 10},
               {:sleep, 300},
               {:set_direction, :axis1, :negative},
               {:step, :axis1, 20},
               :stop
             ]
    end

    test "handles all three axes" do
      text = """
      X speed 30
      Y speed 50
      Z speed 75
      """

      assert {:ok, instructions} = Program.parse(text)

      assert instructions == [
               {:set_speed, :axis1, 30},
               {:set_speed, :axis2, 50},
               {:set_speed, :axis3, 75}
             ]
    end

    test "is case-insensitive" do
      assert {:ok, [{:set_speed, :axis1, 40}]} = Program.parse("x SPEED 40")
      assert {:ok, [{:set_direction, :axis2, :positive}]} = Program.parse("Y POSITIVE")
    end

    test "ignores blank lines and comments" do
      text = """
      # This is a comment
      X speed 30

      # Another comment
      Y speed 60
      """

      assert {:ok, instructions} = Program.parse(text)

      assert instructions == [
               {:set_speed, :axis1, 30},
               {:set_speed, :axis2, 60}
             ]
    end

    test "handles inline comments" do
      assert {:ok, [{:set_speed, :axis1, 50}]} = Program.parse("X speed 50 # go fast")
    end

    test "accepts forward/backward as direction aliases" do
      assert {:ok, [{:set_direction, :axis1, :positive}]} = Program.parse("X forward")
      assert {:ok, [{:set_direction, :axis1, :negative}]} = Program.parse("X backward")
    end

    test "returns error for speed > max" do
      assert {:error, {1, "speed must be 0-75"}} = Program.parse("X speed 76")
    end

    test "returns error for unknown axis" do
      assert {:error, {1, "unknown axis: w"}} = Program.parse("W speed 100")
    end

    test "returns error for unknown command" do
      assert {:error, {1, "unknown command: rotate"}} = Program.parse("X rotate 100")
    end

    test "returns error for invalid speed value" do
      assert {:error, {1, "invalid speed value"}} = Program.parse("X speed abc")
    end

    test "returns error for invalid sleep duration" do
      assert {:error, {1, "invalid sleep duration"}} = Program.parse("sleep abc")
    end

    test "returns error for invalid step duration" do
      assert {:error, {1, "invalid step duration"}} = Program.parse("X step abc")
    end

    test "returns error with correct line number" do
      text = """
      X speed 30
      Y speed 60
      Z speed 999
      """

      assert {:error, {3, "speed must be 0-75"}} = Program.parse(text)
    end

    test "parses empty input" do
      assert {:ok, []} = Program.parse("")
      assert {:ok, []} = Program.parse("# only comments")
    end

    test "accepts speed 0" do
      assert {:ok, [{:set_speed, :axis1, 0}]} = Program.parse("X speed 0")
    end
  end
end
