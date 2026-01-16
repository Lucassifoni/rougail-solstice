defmodule RougailSolstice.Interferometry.DFT.NxTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.DFT.Nx, as: DFTNx

  @sample_image_path "priv/static/samples/_MG_8459.JPG"

  describe "compute_magnitude_preview/2" do
    test "generates a valid PNG from sample image" do
      image_binary = File.read!(@sample_image_path)

      circle = %{cx: 2500, cy: 1700, r: 1200}

      assert {:ok, png_binary} = DFTNx.compute_magnitude_preview(image_binary, circle)

      assert is_binary(png_binary)
      assert byte_size(png_binary) > 1000
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = png_binary
    end

    test "handles different circle sizes" do
      image_binary = File.read!(@sample_image_path)

      small_circle = %{cx: 2500, cy: 1700, r: 500}
      large_circle = %{cx: 2500, cy: 1700, r: 1500}

      assert {:ok, png_small} = DFTNx.compute_magnitude_preview(image_binary, small_circle)
      assert {:ok, png_large} = DFTNx.compute_magnitude_preview(image_binary, large_circle)

      assert byte_size(png_small) > 0
      assert byte_size(png_large) > 0
    end

    test "respects dft_size option" do
      image_binary = File.read!(@sample_image_path)
      circle = %{cx: 2500, cy: 1700, r: 1200}

      assert {:ok, png_256} = DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: 256)
      assert {:ok, png_512} = DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: 512)

      mat_256 = Evision.imdecode(png_256, Evision.Constant.cv_IMREAD_GRAYSCALE())
      mat_512 = Evision.imdecode(png_512, Evision.Constant.cv_IMREAD_GRAYSCALE())

      assert mat_256.shape == {256, 256}
      assert mat_512.shape == {512, 512}
    end

    test "returns error for invalid image data" do
      invalid_binary = "not an image"
      circle = %{cx: 100, cy: 100, r: 50}

      assert {:error, _reason} = DFTNx.compute_magnitude_preview(invalid_binary, circle)
    end
  end
end
