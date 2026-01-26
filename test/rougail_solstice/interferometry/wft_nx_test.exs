defmodule RougailSolstice.Interferometry.WFT.NxTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.WFT
  alias RougailSolstice.Interferometry.WFT.Nx, as: WFTNx

  @sample_wft_path "priv/static/samples/sample.wft"

  describe "parse_file/1" do
    test "parses sample WFT file with correct dimensions" do
      assert {:ok, wft} = WFTNx.parse_file(@sample_wft_path)

      assert wft.width == 640
      assert wft.height == 640
      assert Nx.shape(wft.data) == {640, 640}
      assert Nx.shape(wft.mask) == {640, 640}
    end

    test "parses metadata correctly" do
      assert {:ok, wft} = WFTNx.parse_file(@sample_wft_path)

      assert wft.outside != nil
      assert wft.diameter == 203.0
      assert wft.roc == 1438.0
      assert wft.lambda == 518.0
    end

    test "computes statistics" do
      assert {:ok, wft} = WFTNx.parse_file(@sample_wft_path)

      assert is_float(wft.min)
      assert is_float(wft.max)
      assert is_float(wft.mean)
      assert is_float(wft.std)
      assert wft.std > 0
    end

    test "returns error for non-existent file" do
      assert {:error, {:read_failed, :enoent}} = WFTNx.parse_file("nonexistent.wft")
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

      assert {:ok, wft} = WFTNx.parse(content)
      assert wft.width == 2
      assert wft.height == 2
      assert Nx.shape(wft.data) == {2, 2}
      assert wft.diameter == 100.0
      assert wft.roc == 500.0
      assert wft.lambda == 550.0
    end
  end

  describe "render_to_png/1" do
    test "renders sample WFT to PNG" do
      assert {:ok, wft} = WFTNx.parse_file(@sample_wft_path)
      assert {:ok, png_binary, metadata} = WFTNx.render_to_png(wft)

      assert is_binary(png_binary)
      assert byte_size(png_binary) > 1000
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = png_binary

      assert is_float(metadata.min)
      assert is_float(metadata.max)
      assert metadata.max > metadata.min
      assert metadata.width == 640
      assert metadata.height == 640
    end
  end

  describe "consistency with list-based WFT" do
    @consistency_tolerance 1.0e-3

    test "produces similar statistics" do
      assert {:ok, wft_nx} = WFTNx.parse_file(@sample_wft_path)
      assert {:ok, wft_list} = WFT.parse_file(@sample_wft_path)

      assert_in_delta wft_nx.mean, wft_list.mean, @consistency_tolerance
      assert_in_delta wft_nx.std, wft_list.std, @consistency_tolerance
      assert_in_delta wft_nx.min, wft_list.min, @consistency_tolerance
      assert_in_delta wft_nx.max, wft_list.max, @consistency_tolerance
      assert_in_delta wft_nx.ref_mean, wft_list.ref_mean, @consistency_tolerance
      assert_in_delta wft_nx.ref_std, wft_list.ref_std, @consistency_tolerance
    end

    test "produces similar data values" do
      assert {:ok, wft_nx} = WFTNx.parse_file(@sample_wft_path)
      assert {:ok, wft_list} = WFT.parse_file(@sample_wft_path)

      nx_data = Nx.to_flat_list(wft_nx.data)
      list_data = List.flatten(wft_list.data)

      sample_indices = [0, 1000, 100_000, 200_000, 300_000, 400_000]

      for idx <- sample_indices do
        nx_val = Enum.at(nx_data, idx)
        list_val = Enum.at(list_data, idx)
        assert_in_delta nx_val, list_val, @consistency_tolerance, "Data mismatch at index #{idx}"
      end
    end

    test "produces similar PNG output" do
      assert {:ok, wft_nx} = WFTNx.parse_file(@sample_wft_path)
      assert {:ok, wft_list} = WFT.parse_file(@sample_wft_path)

      assert {:ok, png_nx, meta_nx} = WFTNx.render_to_png(wft_nx)
      assert {:ok, png_list, meta_list} = WFT.render_to_png(wft_list)

      assert_in_delta meta_nx.min, meta_list.min, @consistency_tolerance
      assert_in_delta meta_nx.max, meta_list.max, @consistency_tolerance

      assert byte_size(png_nx) > 0
      assert byte_size(png_list) > 0
    end
  end
end
