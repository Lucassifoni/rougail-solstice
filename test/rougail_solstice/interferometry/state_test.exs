defmodule RougailSolstice.Interferometry.StateTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.State

  describe "new/0" do
    test "creates initial state with defaults" do
      state = State.new()
      assert state.outline_circle == %{cx: 0, cy: 0, r: 100}
      assert state.center_filter_radius == 10
      assert state.liveview_active == false
      assert state.preview_frame_path == nil
      assert state.full_shot_path == nil
      assert state.optical_params == nil
      assert state.last_analysis == nil
    end
  end

  describe "set_outline_circle/2" do
    test "updates outline circle" do
      state = State.new()
      updated = State.set_outline_circle(state, %{cx: 100, cy: 200, r: 150})
      assert updated.outline_circle == %{cx: 100, cy: 200, r: 150}
    end
  end

  describe "set_center_filter_radius/2" do
    test "updates center filter with valid radius" do
      state = State.new()
      assert {:ok, updated} = State.set_center_filter_radius(state, 20)
      assert updated.center_filter_radius == 20
    end

    test "rejects zero radius" do
      state = State.new()
      assert {:error, :invalid_radius} = State.set_center_filter_radius(state, 0)
    end

    test "rejects negative radius" do
      state = State.new()
      assert {:error, :invalid_radius} = State.set_center_filter_radius(state, -5)
    end

    test "rejects non-integer radius" do
      state = State.new()
      assert {:error, :invalid_radius} = State.set_center_filter_radius(state, 10.5)
    end
  end

  describe "set_optical_params/2" do
    test "updates optical params" do
      state = State.new()

      params = %{
        diameter: 203.0,
        roc: 1438.0,
        lambda: 518.0,
        conic: -1.0,
        obstruction: 0.0
      }

      updated = State.set_optical_params(state, params)
      assert updated.optical_params == params
    end
  end

  describe "set_preview_frame/3" do
    test "updates preview frame path and dimensions" do
      state = State.new()
      updated = State.set_preview_frame(state, "/tmp/preview.jpg", {640, 480})
      assert updated.preview_frame_path == "/tmp/preview.jpg"
      assert updated.preview_dimensions == {640, 480}
    end
  end

  describe "set_full_shot/3" do
    test "updates full shot path and dimensions" do
      state = State.new()
      updated = State.set_full_shot(state, "/tmp/capture.jpg", {3456, 2304})
      assert updated.full_shot_path == "/tmp/capture.jpg"
      assert updated.full_shot_dimensions == {3456, 2304}
    end
  end

  describe "set_dft_preview/2" do
    test "updates dft preview path" do
      state = State.new()
      updated = State.set_dft_preview(state, "/tmp/dft.png")
      assert updated.dft_preview_path == "/tmp/dft.png"
    end
  end

  describe "set_analysis/2" do
    test "updates analysis results" do
      state = State.new()

      analysis = %{
        rms_waves: 0.058,
        pv_waves: 0.36,
        strehl: 0.87
      }

      updated = State.set_analysis(state, analysis)
      assert updated.last_analysis == analysis
    end
  end

  describe "clear_analysis/1" do
    test "clears analysis results" do
      state =
        State.new()
        |> State.set_analysis(%{rms_waves: 0.058})

      updated = State.clear_analysis(state)
      assert updated.last_analysis == nil
    end
  end

  describe "start_liveview/1" do
    test "sets liveview_active to true" do
      state = State.new()
      updated = State.start_liveview(state)
      assert updated.liveview_active == true
    end
  end

  describe "stop_liveview/1" do
    test "sets liveview_active to false" do
      state =
        State.new()
        |> State.start_liveview()

      updated = State.stop_liveview(state)
      assert updated.liveview_active == false
    end
  end

  describe "ready_for_analysis?/1" do
    test "returns false without optical params" do
      state = State.new()
      refute State.ready_for_analysis?(state)
    end

    test "returns false without full shot" do
      state =
        State.new()
        |> State.set_optical_params(%{
          diameter: 203.0,
          roc: 1438.0,
          lambda: 518.0,
          conic: -1.0,
          obstruction: 0.0
        })

      refute State.ready_for_analysis?(state)
    end

    test "returns false with zero radius circle" do
      state =
        State.new()
        |> State.set_optical_params(%{
          diameter: 203.0,
          roc: 1438.0,
          lambda: 518.0,
          conic: -1.0,
          obstruction: 0.0
        })
        |> State.set_full_shot("/tmp/capture.jpg", {3456, 2304})
        |> State.set_outline_circle(%{cx: 100, cy: 100, r: 0})

      refute State.ready_for_analysis?(state)
    end

    test "returns true when fully configured" do
      state =
        State.new()
        |> State.set_optical_params(%{
          diameter: 203.0,
          roc: 1438.0,
          lambda: 518.0,
          conic: -1.0,
          obstruction: 0.0
        })
        |> State.set_full_shot("/tmp/capture.jpg", {3456, 2304})
        |> State.set_outline_circle(%{cx: 100, cy: 100, r: 80})

      assert State.ready_for_analysis?(state)
    end
  end

  describe "ready_for_dft_preview?/1" do
    test "returns false without preview frame" do
      state = State.new()
      refute State.ready_for_dft_preview?(state)
    end

    test "returns false with zero radius" do
      state =
        State.new()
        |> State.set_preview_frame("/tmp/preview.jpg", {640, 480})
        |> State.set_outline_circle(%{cx: 100, cy: 100, r: 0})

      refute State.ready_for_dft_preview?(state)
    end

    test "returns true with preview frame and valid circle" do
      state =
        State.new()
        |> State.set_preview_frame("/tmp/preview.jpg", {640, 480})
        |> State.set_outline_circle(%{cx: 100, cy: 100, r: 80})

      assert State.ready_for_dft_preview?(state)
    end
  end

  describe "scale_circle_to_full_shot/1" do
    test "scales circle from preview to full shot dimensions" do
      state =
        State.new()
        |> State.set_preview_frame("/tmp/preview.jpg", {640, 480})
        |> State.set_full_shot("/tmp/capture.jpg", {3200, 2400})
        |> State.set_outline_circle(%{cx: 320, cy: 240, r: 100})

      assert {:ok, scaled} = State.scale_circle_to_full_shot(state)
      assert scaled.cx == 1600.0
      assert scaled.cy == 1200.0
      assert scaled.r == 500.0
    end

    test "returns error without preview dimensions" do
      state =
        State.new()
        |> State.set_full_shot("/tmp/capture.jpg", {3200, 2400})
        |> State.set_outline_circle(%{cx: 320, cy: 240, r: 100})

      assert {:error, :missing_dimensions} = State.scale_circle_to_full_shot(state)
    end

    test "returns error without full shot dimensions" do
      state =
        State.new()
        |> State.set_preview_frame("/tmp/preview.jpg", {640, 480})
        |> State.set_outline_circle(%{cx: 320, cy: 240, r: 100})

      assert {:error, :missing_dimensions} = State.scale_circle_to_full_shot(state)
    end
  end
end
