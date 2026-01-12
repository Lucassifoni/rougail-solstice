defmodule RougailSolstice.Interferometry.Sidecar.ProtocolTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.Sidecar.Protocol

  describe "encode_config/1" do
    test "encodes minimal config" do
      result = Protocol.encode_config(%{diameter: 203})
      encoded = IO.iodata_to_binary(result)

      assert encoded =~ "cmd\tconfig\n"
      assert encoded =~ "diameter\t203\n"
      assert String.ends_with?(encoded, "---\n")
    end

    test "encodes full config" do
      config = %{
        diameter: 203,
        roc: 1438,
        lambda: 518,
        conic: -1.33,
        obstruction: 0.25,
        dft_size: 640,
        center_filter: 10.5,
        do_null: true,
        auto_invert: false
      }

      result = Protocol.encode_config(config)
      encoded = IO.iodata_to_binary(result)

      assert encoded =~ "cmd\tconfig\n"
      assert encoded =~ "diameter\t203\n"
      assert encoded =~ "roc\t1438\n"
      assert encoded =~ "lambda\t518\n"
      assert encoded =~ "conic\t-1.33\n"
      assert encoded =~ "obstruction\t0.25\n"
      assert encoded =~ "dft_size\t640\n"
      assert encoded =~ "center_filter\t10.5\n"
      assert encoded =~ "do_null\ttrue\n"
      assert encoded =~ "auto_invert\tfalse\n"
    end

    test "omits unset fields" do
      result = Protocol.encode_config(%{diameter: 100})
      encoded = IO.iodata_to_binary(result)

      refute encoded =~ "roc\t"
      refute encoded =~ "lambda\t"
    end
  end

  describe "encode_preview/2" do
    test "encodes preview request with circle" do
      image = "fake image data"
      circle = %{cx: 320, cy: 240, r: 200}

      result = Protocol.encode_preview(image, circle)
      encoded = IO.iodata_to_binary(result)

      assert encoded =~ "cmd\tpreview\n"
      assert encoded =~ "image\t#{Base.encode64(image)}\n"
      assert encoded =~ "outside_cx\t320\n"
      assert encoded =~ "outside_cy\t240\n"
      assert encoded =~ "outside_r\t200\n"
      assert String.ends_with?(encoded, "---\n")
    end

    test "includes center obstruction when present" do
      image = "data"
      circle = %{cx: 320, cy: 240, r: 200, center_cx: 320, center_cy: 240, center_r: 50}

      result = Protocol.encode_preview(image, circle)
      encoded = IO.iodata_to_binary(result)

      assert encoded =~ "center_cx\t320\n"
      assert encoded =~ "center_cy\t240\n"
      assert encoded =~ "center_r\t50\n"
    end
  end

  describe "encode_analyze/2" do
    test "encodes analyze request" do
      image = "image data"
      circle = %{cx: 100, cy: 200, r: 150}

      result = Protocol.encode_analyze(image, circle)
      encoded = IO.iodata_to_binary(result)

      assert encoded =~ "cmd\tanalyze\n"
      assert encoded =~ "image\t#{Base.encode64(image)}\n"
      assert encoded =~ "outside_cx\t100\n"
      assert encoded =~ "outside_cy\t200\n"
      assert encoded =~ "outside_r\t150\n"
    end
  end

  describe "encode_quit/0" do
    test "encodes quit command" do
      result = Protocol.encode_quit()
      encoded = IO.iodata_to_binary(result)

      assert encoded == "cmd\tquit\n---\n"
    end
  end

  describe "decode_response/1" do
    test "decodes successful preview response" do
      dft_base64 = Base.encode64("png data")

      response = """
      status\tok
      dft\t#{dft_base64}
      ---
      """

      assert {:ok, result} = Protocol.decode_response(response)
      assert result.status == "ok"
      assert result.dft == dft_base64
    end

    test "decodes successful analyze response" do
      response = """
      status\tok
      rms\t0.058
      pv\t0.36
      strehl\t0.87
      z0\t9.689
      z1\t17.017
      z8\t-0.003
      inverted\ttrue
      null_applied\tfalse
      ---
      """

      assert {:ok, result} = Protocol.decode_response(response)
      assert result.status == "ok"
      assert result.rms == 0.058
      assert result.pv == 0.36
      assert result.strehl == 0.87
      assert result.z0 == 9.689
      assert result.z1 == 17.017
      assert result.z8 == -0.003
      assert result.inverted == true
      assert result.null_applied == false
    end

    test "decodes error response" do
      response = """
      status\terror
      message\tCannot decode image
      ---
      """

      assert {:error, "Cannot decode image"} = Protocol.decode_response(response)
    end

    test "returns error for missing status" do
      response = "rms\t0.05\n---\n"
      assert {:error, "Missing status field"} = Protocol.decode_response(response)
    end

    test "handles negative zernike values" do
      response = """
      status\tok
      z8\t-5.73
      ---
      """

      assert {:ok, result} = Protocol.decode_response(response)
      assert result.z8 == -5.73
    end
  end

  describe "find_terminator/1" do
    test "finds complete message" do
      buffer = "status\tok\nrms\t0.05\n---\n"
      assert {:complete, ^buffer, ""} = Protocol.find_terminator(buffer)
    end

    test "finds complete message with remainder" do
      buffer = "status\tok\n---\nstatus\tok\n"

      assert {:complete, complete, rest} = Protocol.find_terminator(buffer)
      assert complete == "status\tok\n---\n"
      assert rest == "status\tok\n"
    end

    test "returns incomplete for partial message" do
      buffer = "status\tok\nrms\t0.05"
      assert :incomplete = Protocol.find_terminator(buffer)
    end

    test "returns incomplete for missing terminator" do
      buffer = "status\tok\n"
      assert :incomplete = Protocol.find_terminator(buffer)
    end
  end
end
