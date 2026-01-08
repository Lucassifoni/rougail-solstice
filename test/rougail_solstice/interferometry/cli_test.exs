defmodule RougailSolstice.Interferometry.CLITest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.CLI

  describe "parse_structured_output/1" do
    test "parses basic metrics" do
      output = """
      mode\tfull
      rms_waves\t0.058
      pv_waves\t0.36
      strehl\t0.87
      """

      assert {:ok, result} = CLI.parse_structured_output(output)
      assert result.rms_waves == 0.058
      assert result.pv_waves == 0.36
      assert result.strehl == 0.87
    end

    test "parses raw zernike coefficients" do
      output = """
      zernike_raw_0\t9.689
      zernike_raw_1\t17.017
      zernike_raw_4\t0.125
      """

      assert {:ok, result} = CLI.parse_structured_output(output)
      assert result.zernikes_raw[0] == 9.689
      assert result.zernikes_raw[1] == 17.017
      assert result.zernikes_raw[4] == 0.125
    end

    test "parses nulled zernike coefficients" do
      output = """
      zernike_nulled_0\t9.689
      zernike_nulled_8\t-0.003
      """

      assert {:ok, result} = CLI.parse_structured_output(output)
      assert result.zernikes_nulled[0] == 9.689
      assert result.zernikes_nulled[8] == -0.003
    end

    test "parses full structured output" do
      output = """
      mode\tfull
      input_file\t/data/sample.jpg
      input_width\t3456
      input_height\t2304
      outline_center_x\t1672.5
      outline_center_y\t1075
      outline_radius\t568
      mirror_diameter\t203
      mirror_roc\t1438
      mirror_lambda\t518
      mirror_conic\t-1.33
      zernike_raw_0\t9.689
      zernike_raw_1\t17.017
      zernike_raw_4\t0.05
      zernike_nulled_0\t9.689
      zernike_nulled_8\t-0.003
      rms_waves\t0.058
      pv_waves\t0.36
      strehl\t0.87
      output_wavefront\t/data/result.wft
      output_zernikes_csv\t/data/zernikes.csv
      """

      assert {:ok, result} = CLI.parse_structured_output(output)
      assert result.rms_waves == 0.058
      assert result.pv_waves == 0.36
      assert result.strehl == 0.87
      assert result.zernikes_raw[0] == 9.689
      assert result.zernikes_raw[1] == 17.017
      assert result.zernikes_raw[4] == 0.05
      assert result.zernikes_nulled[0] == 9.689
      assert result.zernikes_nulled[8] == -0.003
    end

    test "handles empty output" do
      assert {:ok, result} = CLI.parse_structured_output("")
      assert result.zernikes_raw == %{}
      assert result.zernikes_nulled == %{}
      assert result.rms_waves == 0.0
      assert result.pv_waves == 0.0
      assert result.strehl == 0.0
    end

    test "ignores unrecognized lines" do
      output = """
      some_random_key\tvalue
      rms_waves\t0.1
      another_key\t123
      """

      assert {:ok, result} = CLI.parse_structured_output(output)
      assert result.rms_waves == 0.1
      refute Map.has_key?(result, :some_random_key)
    end

    test "handles negative values" do
      output = """
      zernike_nulled_8\t-5.73
      rms_waves\t0.058
      """

      assert {:ok, result} = CLI.parse_structured_output(output)
      assert result.zernikes_nulled[8] == -5.73
    end
  end
end
