defmodule RougailSolstice.Outline.StateTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Outline.State

  defp make_frame(n) do
    %{binary: <<n>>, dimensions: {640, 480}, timestamp: n}
  end

  describe "new/1" do
    test "creates state with defaults" do
      state = State.new()
      assert state.enabled == false
      assert state.max_frames == 50
      assert state.threshold_percentile == 0.8
      assert state.min_confidence == 0.7
      assert State.frame_count(state) == 0
    end

    test "accepts custom options" do
      state = State.new(max_frames: 5, threshold_percentile: 0.85, min_confidence: 0.8)
      assert state.max_frames == 5
      assert state.threshold_percentile == 0.85
      assert state.min_confidence == 0.8
    end
  end

  describe "enable/1 and disable/1" do
    test "enable sets enabled to true" do
      state = State.new() |> State.enable()
      assert state.enabled == true
    end

    test "disable sets enabled to false and clears frames" do
      state =
        State.new()
        |> State.enable()
        |> State.push_frame(make_frame(1))
        |> State.push_frame(make_frame(2))
        |> State.disable()

      assert state.enabled == false
      assert State.frame_count(state) == 0
    end

    test "disable resets consecutive_failures" do
      state =
        State.new()
        |> State.record_failure()
        |> State.record_failure()
        |> State.disable()

      assert state.consecutive_failures == 0
    end
  end

  describe "push_frame/2" do
    test "adds frame to queue" do
      state = State.new() |> State.push_frame(make_frame(1))
      assert State.frame_count(state) == 1
    end

    test "maintains max_frames limit" do
      state = State.new(max_frames: 3)

      state =
        Enum.reduce(1..5, state, fn n, s ->
          State.push_frame(s, make_frame(n))
        end)

      assert State.frame_count(state) == 3

      frames = State.get_frames(state)
      assert length(frames) == 3
      assert Enum.map(frames, & &1.timestamp) == [3, 4, 5]
    end
  end

  describe "ready_for_detection?/1" do
    test "returns false when not enabled" do
      state =
        State.new(max_frames: 2)
        |> State.push_frame(make_frame(1))
        |> State.push_frame(make_frame(2))

      refute State.ready_for_detection?(state)
    end

    test "returns false when not enough frames" do
      state =
        State.new(max_frames: 3)
        |> State.enable()
        |> State.push_frame(make_frame(1))
        |> State.push_frame(make_frame(2))

      refute State.ready_for_detection?(state)
    end

    test "returns true when enabled and enough frames" do
      state =
        State.new(max_frames: 2)
        |> State.enable()
        |> State.push_frame(make_frame(1))
        |> State.push_frame(make_frame(2))

      assert State.ready_for_detection?(state)
    end
  end

  describe "set_detection/2" do
    test "stores detection result and resets failures" do
      result = %{
        circle: %{cx: 320.0, cy: 240.0, r: 200.0},
        confidence: 0.85,
        method: :hough,
        detected_at: 12_345
      }

      state =
        State.new()
        |> State.record_failure()
        |> State.record_failure()
        |> State.set_detection(result)

      assert state.last_detection == result
      assert state.consecutive_failures == 0
    end
  end

  describe "record_failure/1 and should_suppress_logging?/1" do
    test "increments consecutive_failures" do
      state =
        State.new()
        |> State.record_failure()
        |> State.record_failure()

      assert state.consecutive_failures == 2
    end

    test "should_suppress_logging? returns true after 5 failures" do
      state = State.new()
      refute State.should_suppress_logging?(state)

      state = Enum.reduce(1..5, state, fn _, s -> State.record_failure(s) end)
      refute State.should_suppress_logging?(state)

      state = State.record_failure(state)
      assert State.should_suppress_logging?(state)
    end
  end

  describe "clear_frames/1" do
    test "empties the frame queue" do
      state =
        State.new()
        |> State.push_frame(make_frame(1))
        |> State.push_frame(make_frame(2))
        |> State.clear_frames()

      assert State.frame_count(state) == 0
    end
  end
end
