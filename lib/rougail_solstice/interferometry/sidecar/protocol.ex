defmodule RougailSolstice.Interferometry.Sidecar.Protocol do
  @moduledoc """
  Protocol encoding/decoding for DFTFringe sidecar communication.

  Messages are tab-separated key-value pairs terminated by "---".
  Binary data (images, outlines, wft) is base64 encoded.
  """

  @terminator "---"

  @type message :: %{String.t() => String.t() | number() | boolean()}

  @spec encode_config(map()) :: iodata()
  def encode_config(config) do
    fields = [{"cmd", "config"}]

    fields =
      fields
      |> maybe_add(config, :diameter)
      |> maybe_add(config, :roc)
      |> maybe_add(config, :lambda)
      |> maybe_add(config, :conic)
      |> maybe_add(config, :obstruction)
      |> maybe_add(config, :fringe_spacing)
      |> maybe_add_bool(config, :flip_v)
      |> maybe_add_bool(config, :flip_h)
      |> maybe_add_bool(config, :do_null)
      |> maybe_add_bool(config, :auto_invert)
      |> maybe_add(config, :dft_size)
      |> maybe_add(config, :center_filter)
      |> maybe_add(config, :smooth)
      |> maybe_add(config, :zernike_terms)

    encode_fields(fields)
  end

  @spec encode_preview(binary(), map()) :: iodata()
  def encode_preview(image_binary, circle) do
    fields = [
      {"cmd", "preview"},
      {"image", Base.encode64(image_binary)},
      {"outside_cx", circle.cx},
      {"outside_cy", circle.cy},
      {"outside_r", circle.r}
    ]

    fields =
      if Map.has_key?(circle, :center_cx) do
        fields ++
          [
            {"center_cx", circle.center_cx},
            {"center_cy", circle.center_cy},
            {"center_r", circle.center_r}
          ]
      else
        fields
      end

    encode_fields(fields)
  end

  @spec encode_analyze(binary(), map()) :: iodata()
  def encode_analyze(image_binary, circle) do
    fields = [
      {"cmd", "analyze"},
      {"image", Base.encode64(image_binary)},
      {"outside_cx", circle.cx},
      {"outside_cy", circle.cy},
      {"outside_r", circle.r}
    ]

    fields =
      if Map.has_key?(circle, :center_cx) do
        fields ++
          [
            {"center_cx", circle.center_cx},
            {"center_cy", circle.center_cy},
            {"center_r", circle.center_r}
          ]
      else
        fields
      end

    encode_fields(fields)
  end

  @spec encode_quit() :: iodata()
  def encode_quit do
    encode_fields([{"cmd", "quit"}])
  end

  @spec decode_response(String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode_response(data) do
    fields =
      data
      |> String.split("\n", trim: true)
      |> Enum.reject(&(&1 == @terminator))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "\t", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    case fields["status"] do
      "ok" -> {:ok, parse_fields(fields)}
      "error" -> {:error, fields["message"] || "Unknown error"}
      nil -> {:error, "Missing status field"}
      other -> {:error, "Unknown status: #{other}"}
    end
  end

  @spec find_terminator(String.t()) :: {:complete, String.t(), String.t()} | :incomplete
  def find_terminator(buffer) do
    case String.split(buffer, "\n#{@terminator}\n", parts: 2) do
      [complete, rest] ->
        {:complete, complete <> "\n#{@terminator}\n", rest}

      [_incomplete] ->
        if String.ends_with?(buffer, "\n#{@terminator}\n") do
          {:complete, buffer, ""}
        else
          :incomplete
        end
    end
  end

  defp encode_fields(fields) do
    lines =
      Enum.map(fields, fn {key, value} ->
        [to_string(key), "\t", format_value(value), "\n"]
      end)

    [lines, @terminator, "\n"]
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 10])

  defp format_value(true), do: "true"
  defp format_value(false), do: "false"

  defp maybe_add(fields, config, key) do
    if Map.has_key?(config, key) do
      fields ++ [{to_string(key), config[key]}]
    else
      fields
    end
  end

  defp maybe_add_bool(fields, config, key) do
    if Map.has_key?(config, key) do
      fields ++ [{to_string(key), if(config[key], do: "true", else: "false")}]
    else
      fields
    end
  end

  defp parse_fields(fields) do
    fields
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      parsed_key = String.to_atom(key)
      parsed_value = parse_value(key, value)
      Map.put(acc, parsed_key, parsed_value)
    end)
  end

  defp parse_value("status", value), do: value
  defp parse_value("message", value), do: value
  defp parse_value("dft", value), do: value
  defp parse_value("wft", value), do: value

  defp parse_value("inverted", value), do: value in ["true", "1", "yes"]
  defp parse_value("null_applied", value), do: value in ["true", "1", "yes"]

  defp parse_value(key, value) do
    cond do
      String.starts_with?(key, "z") and numeric_suffix?(key) ->
        parse_float(value)

      key in ~w(rms pv strehl null_value) ->
        parse_float(value)

      true ->
        value
    end
  end

  defp numeric_suffix?(key) do
    key
    |> String.slice(1..-1//1)
    |> Integer.parse()
    |> case do
      {_, ""} -> true
      _ -> false
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end
