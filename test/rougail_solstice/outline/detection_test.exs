defmodule RougailSolstice.Outline.DetectionTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Outline.Detection

  @samples_dir "priv/static/samples"

  defp load_sample_images do
    Path.wildcard(Path.join(@samples_dir, "*.JPG"))
    |> Enum.sort()
    |> Enum.map(&File.read!/1)
  end

  defp encode_jpeg(mat) do
    case Evision.imencode(".jpg", mat) do
      binary when is_binary(binary) -> binary
      {:ok, binary} -> binary
    end
  end

  @test_width 640
  @test_height 480

  describe "run_detection/3" do
    test "detects circle from sample images" do
      binaries = load_sample_images()
      assert length(binaries) >= 2, "need at least 2 sample images"

      first_image = Evision.imdecode(hd(binaries), Evision.Constant.cv_IMREAD_GRAYSCALE())

      {height, width} =
        Evision.Mat.shape(first_image) |> Tuple.to_list() |> Enum.take(2) |> List.to_tuple()

      result =
        Detection.run_detection(binaries, {width, height},
          min_confidence: 0.1,
          debug_save: false
        )

      assert {:ok, detection} = result
      assert detection.confidence >= 0.1
      assert detection.circle.cx > 0
      assert detection.circle.cy > 0
      assert detection.circle.r > 0
      assert detection.circle.cx < width
      assert detection.circle.cy < height
    end

    test "detects circle with consistent results across runs" do
      binaries = load_sample_images()
      first_image = Evision.imdecode(hd(binaries), Evision.Constant.cv_IMREAD_GRAYSCALE())

      {height, width} =
        Evision.Mat.shape(first_image) |> Tuple.to_list() |> Enum.take(2) |> List.to_tuple()

      results =
        Enum.map(1..3, fn _ ->
          Detection.run_detection(binaries, {width, height},
            min_confidence: 0.1,
            debug_save: false
          )
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      detections = Enum.map(results, fn {:ok, d} -> d end)
      first = hd(detections)

      Enum.each(detections, fn detection ->
        assert_in_delta detection.circle.cx, first.circle.cx, 5
        assert_in_delta detection.circle.cy, first.circle.cy, 5
        assert_in_delta detection.circle.r, first.circle.r, 5
      end)
    end

    test "returns error for empty input" do
      assert {:error, :no_frames} = Detection.run_detection([], {@test_width, @test_height})
    end

    test "returns no_detection for uniform images" do
      uniform = Evision.Mat.zeros({@test_height, @test_width}, :u8)
      binaries = Enum.map(1..10, fn _ -> encode_jpeg(uniform) end)

      result =
        Detection.run_detection(binaries, {@test_width, @test_height},
          min_confidence: 0.7,
          debug_save: false
        )

      assert {:error, :no_detection} = result
    end
  end
end
