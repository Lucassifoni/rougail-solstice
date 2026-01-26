defmodule RougailSolstice.Robot.CameraAdapter.Liveview.JpegParser do
  @moduledoc """
  Pure module for extracting JPEG frames from a binary stream.

  Handles gphoto2's --capture-movie --stdout output format, which emits
  continuous JPEG frames delimited by SOI (0xFFD8) and EOI (0xFFD9) markers.

  Accumulates partial data across reads and returns complete frames.
  """

  @jpeg_soi <<0xFF, 0xD8>>
  @jpeg_eoi <<0xFF, 0xD9>>

  @type state :: %{buffer: binary()}

  @spec new() :: state()
  def new, do: %{buffer: <<>>}

  @spec push(state(), binary()) :: {[binary()], state()}
  def push(%{buffer: buffer} = _state, data) do
    combined = buffer <> data
    {frames, remaining} = extract_frames(combined)
    {frames, %{buffer: remaining}}
  end

  @spec extract_frames(binary()) :: {[binary()], binary()}
  def extract_frames(data) do
    extract_frames(data, [])
  end

  defp extract_frames(data, acc) do
    case find_frame(data) do
      {:ok, frame, rest} ->
        extract_frames(rest, [frame | acc])

      :incomplete ->
        {Enum.reverse(acc), data}
    end
  end

  defp find_frame(data) do
    case find_soi(data) do
      {:ok, soi_pos} ->
        after_soi = binary_part(data, soi_pos, byte_size(data) - soi_pos)

        case find_eoi(after_soi) do
          {:ok, eoi_pos} ->
            frame_end = eoi_pos + 2
            frame = binary_part(after_soi, 0, frame_end)
            rest_start = soi_pos + frame_end
            rest = binary_part(data, rest_start, byte_size(data) - rest_start)
            {:ok, frame, rest}

          :not_found ->
            :incomplete
        end

      :not_found ->
        :incomplete
    end
  end

  defp find_soi(data), do: find_marker(data, @jpeg_soi, 0)

  defp find_eoi(data), do: find_eoi(data, 2)

  defp find_eoi(data, offset) when offset >= byte_size(data), do: :not_found

  defp find_eoi(data, offset) do
    remaining = byte_size(data) - offset

    case :binary.match(data, @jpeg_eoi, scope: {offset, remaining}) do
      {pos, 2} -> {:ok, pos}
      :nomatch -> :not_found
    end
  end

  defp find_marker(data, _marker, offset) when offset > byte_size(data) - 2, do: :not_found

  defp find_marker(data, marker, offset) do
    remaining = byte_size(data) - offset

    case :binary.match(data, marker, scope: {offset, remaining}) do
      {pos, 2} -> {:ok, pos}
      :nomatch -> :not_found
    end
  end

  @doc """
  Returns the JPEG SOI marker bytes.
  """
  @spec soi_marker() :: binary()
  def soi_marker, do: @jpeg_soi

  @doc """
  Returns the JPEG EOI marker bytes.
  """
  @spec eoi_marker() :: binary()
  def eoi_marker, do: @jpeg_eoi
end
