defmodule RougailSolstice.Robot.CameraAdapter.Liveview.JpegParserTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Robot.CameraAdapter.Liveview.JpegParser

  @soi JpegParser.soi_marker()
  @eoi JpegParser.eoi_marker()

  defp make_frame(payload) do
    @soi <> payload <> @eoi
  end

  describe "new/0" do
    test "creates state with empty buffer" do
      state = JpegParser.new()
      assert state == %{buffer: <<>>}
    end
  end

  describe "extract_frames/1" do
    test "extracts single complete frame" do
      frame = make_frame(<<1, 2, 3, 4, 5>>)
      {frames, rest} = JpegParser.extract_frames(frame)
      assert frames == [frame]
      assert rest == <<>>
    end

    test "extracts multiple complete frames" do
      frame1 = make_frame(<<1, 2, 3>>)
      frame2 = make_frame(<<4, 5, 6>>)
      data = frame1 <> frame2

      {frames, rest} = JpegParser.extract_frames(data)
      assert frames == [frame1, frame2]
      assert rest == <<>>
    end

    test "returns incomplete frame in rest" do
      complete = make_frame(<<1, 2, 3>>)
      partial = @soi <> <<7, 8, 9>>
      data = complete <> partial

      {frames, rest} = JpegParser.extract_frames(data)
      assert frames == [complete]
      assert rest == partial
    end

    test "handles data with no complete frames" do
      partial = @soi <> <<1, 2, 3>>
      {frames, rest} = JpegParser.extract_frames(partial)
      assert frames == []
      assert rest == partial
    end

    test "handles empty data" do
      {frames, rest} = JpegParser.extract_frames(<<>>)
      assert frames == []
      assert rest == <<>>
    end

    test "handles garbage before first frame" do
      garbage = <<99, 98, 97>>
      frame = make_frame(<<1, 2, 3>>)
      data = garbage <> frame

      {frames, rest} = JpegParser.extract_frames(data)
      assert frames == [frame]
      assert rest == <<>>
    end

    test "handles data with only EOI marker" do
      data = @eoi
      {frames, rest} = JpegParser.extract_frames(data)
      assert frames == []
      assert rest == @eoi
    end

    test "handles data with only SOI marker" do
      data = @soi
      {frames, rest} = JpegParser.extract_frames(data)
      assert frames == []
      assert rest == @soi
    end

    test "handles frame with 0xFF bytes in payload" do
      payload_with_ff = <<0x01, 0xFF, 0x02, 0xFF, 0x03>>
      frame = make_frame(payload_with_ff)
      {frames, rest} = JpegParser.extract_frames(frame)
      assert frames == [frame]
      assert rest == <<>>
    end

    test "stops at first EOI marker (JPEG encoding escapes internal markers)" do
      data = @soi <> <<0xFF, 0xD8, 0x00>> <> @eoi <> <<0x00>> <> @eoi
      {[extracted], rest} = JpegParser.extract_frames(data)
      assert extracted == @soi <> <<0xFF, 0xD8, 0x00>> <> @eoi
      assert rest == <<0x00>> <> @eoi
    end
  end

  describe "push/2" do
    test "accumulates partial data across calls" do
      state = JpegParser.new()

      part1 = @soi <> <<1, 2>>
      {frames1, state} = JpegParser.push(state, part1)
      assert frames1 == []

      part2 = <<3, 4>> <> @eoi
      {frames2, state} = JpegParser.push(state, part2)
      assert frames2 == [make_frame(<<1, 2, 3, 4>>)]
      assert state.buffer == <<>>
    end

    test "handles split SOI marker" do
      state = JpegParser.new()

      {frames1, state} = JpegParser.push(state, <<0xFF>>)
      assert frames1 == []

      {frames2, state} = JpegParser.push(state, <<0xD8, 1, 2, 3>> <> @eoi)
      assert frames2 == [make_frame(<<1, 2, 3>>)]
      assert state.buffer == <<>>
    end

    test "handles split EOI marker" do
      state = JpegParser.new()

      {frames1, state} = JpegParser.push(state, @soi <> <<1, 2, 3, 0xFF>>)
      assert frames1 == []

      {frames2, state} = JpegParser.push(state, <<0xD9>>)
      assert frames2 == [make_frame(<<1, 2, 3>>)]
      assert state.buffer == <<>>
    end

    test "returns multiple frames from single push" do
      state = JpegParser.new()
      frame1 = make_frame(<<1>>)
      frame2 = make_frame(<<2>>)
      frame3 = make_frame(<<3>>)

      {frames, state} = JpegParser.push(state, frame1 <> frame2 <> frame3)
      assert frames == [frame1, frame2, frame3]
      assert state.buffer == <<>>
    end

    test "handles continuous stream simulation" do
      state = JpegParser.new()
      all_frames = []

      {frames, state} = JpegParser.push(state, @soi <> <<1, 2>>)
      all_frames = all_frames ++ frames

      {frames, state} = JpegParser.push(state, <<3>> <> @eoi <> @soi)
      all_frames = all_frames ++ frames

      {frames, state} = JpegParser.push(state, <<4, 5>> <> @eoi <> @soi <> <<6>>)
      all_frames = all_frames ++ frames

      {frames, _state} = JpegParser.push(state, <<7>> <> @eoi)
      all_frames = all_frames ++ frames

      assert all_frames == [
               make_frame(<<1, 2, 3>>),
               make_frame(<<4, 5>>),
               make_frame(<<6, 7>>)
             ]
    end
  end

  describe "markers" do
    test "soi_marker returns correct bytes" do
      assert JpegParser.soi_marker() == <<0xFF, 0xD8>>
    end

    test "eoi_marker returns correct bytes" do
      assert JpegParser.eoi_marker() == <<0xFF, 0xD9>>
    end
  end
end
