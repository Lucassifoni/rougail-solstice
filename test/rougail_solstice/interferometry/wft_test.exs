defmodule RougailSolstice.Interferometry.WFTTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.WFT

  @sample_wft_path "priv/static/samples/sample.wft"

  describe "parse_file/1" do
    test "parses sample WFT file" do
      assert {:ok, wft} = WFT.parse_file(@sample_wft_path)

      assert wft.width == 640
      assert wft.height == 640
      assert Nx.shape(wft.data) == {640, 640}

      assert wft.outside_circle != nil
      assert wft.outside_circle.cx == 319.5
      assert wft.outside_circle.cy == 319.5
      assert wft.outside_circle.r == 319.5

      assert wft.diameter == 203.0
      assert wft.roc == 1438.0
      assert wft.lambda == 518.0
    end

    test "returns error for non-existent file" do
      assert {:error, {:read_failed, :enoent}} = WFT.parse_file("nonexistent.wft")
    end
  end

  describe "parse/1" do
    test "parses minimal WFT content" do
      content = """
      2
      2
      1.0
      2.0
      3.0
      4.0
      outside ellipse 1 1 1 1
      DIAM 100
      ROC 500
      Lambda 550
      """

      assert {:ok, wft} = WFT.parse(content)
      assert wft.width == 2
      assert wft.height == 2
      assert Nx.shape(wft.data) == {2, 2}
      assert wft.diameter == 100.0
      assert wft.roc == 500.0
      assert wft.lambda == 550.0
    end

    test "handles empty content" do
      assert {:error, :empty_file} = WFT.parse("")
    end
  end

  describe "render_to_png/2" do
    test "renders sample WFT to PNG" do
      assert {:ok, wft} = WFT.parse_file(@sample_wft_path)
      assert {:ok, png_binary} = WFT.render_to_png(wft, size: 256)

      assert is_binary(png_binary)
      assert byte_size(png_binary) > 1000

      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = png_binary
    end

    test "renders with custom size" do
      assert {:ok, wft} = WFT.parse_file(@sample_wft_path)
      assert {:ok, png_binary} = WFT.render_to_png(wft, size: 128)

      assert is_binary(png_binary)
    end
  end
end
