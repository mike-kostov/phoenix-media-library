defmodule PhxMediaLibrary.VideoProcessor.FFmpeg do
  @moduledoc """
  Video processor implementation using `ffprobe` and `ffmpeg`.

  Requires both executables to be installed and available on `$PATH`.
  Used automatically when `available?/0` returns `true`.

  ## Metadata extraction

  Runs:

      ffprobe -v quiet -print_format json -show_streams -show_format <file>

  and parses the JSON output to produce:

    * `"duration"` — total duration in seconds (float)
    * `"width"` / `"height"` — video stream dimensions (integer)
    * `"codec"` — video codec name, e.g. `"h264"` or `"vp9"` (string)
    * `"fps"` — frames per second derived from `r_frame_rate`, e.g. `30.0` (float)
    * `"audio_codec"` — first audio stream codec, e.g. `"aac"` (string, optional)
    * `"bit_rate"` — overall bit rate in bits/s from the format section (integer, optional)

  ## Poster frame extraction

  Runs:

      ffmpeg -ss <offset> -i <file> -frames:v 1 -f image2pipe -vcodec mjpeg pipe:1

  and returns the raw JPEG bytes.

  ## Availability

  `available?/0` checks for both `ffprobe` and `ffmpeg` via
  `System.find_executable/1`. Returns `false` if either is missing, causing
  the library to fall back to `PhxMediaLibrary.VideoProcessor.Null` silently.

  ## Installation

      # macOS
      brew install ffmpeg

      # Ubuntu / Debian
      apt-get install ffmpeg
  """

  @behaviour PhxMediaLibrary.VideoProcessor

  @impl true
  @doc """
  Returns `true` when both `ffprobe` and `ffmpeg` are found on `$PATH`.
  """
  @spec available?() :: boolean()
  def available? do
    not is_nil(System.find_executable("ffprobe")) and
      not is_nil(System.find_executable("ffmpeg"))
  end

  @impl true
  @doc """
  Extract metadata from a video file using `ffprobe`.

  Returns `{:ok, metadata}` on success, or `{:error, reason}` on failure.
  Returns `{:error, :ffmpeg_not_available}` when `ffprobe` is not on `$PATH`.
  """
  @spec extract_metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def extract_metadata(file_path) do
    case System.find_executable("ffprobe") do
      nil ->
        {:error, :ffmpeg_not_available}

      ffprobe ->
        args = [
          "-v",
          "quiet",
          "-print_format",
          "json",
          "-show_streams",
          "-show_format",
          file_path
        ]

        case System.cmd(ffprobe, args, stderr_to_stdout: false) do
          {output, 0} -> parse_ffprobe_output(output)
          {output, code} -> {:error, {:ffprobe_failed, code, output}}
        end
    end
  end

  @impl true
  @doc """
  Extract a JPEG poster frame from a video using `ffmpeg`.

  `offset_seconds` specifies where in the video to capture the frame and is
  clamped to `>= 0.0`. Returns `{:ok, jpeg_binary}` on success.
  Returns `{:error, :ffmpeg_not_available}` when `ffmpeg` is not on `$PATH`.
  """
  @spec extract_poster(String.t(), float()) :: {:ok, binary()} | {:error, term()}
  def extract_poster(file_path, offset_seconds \\ 0.0) do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error, :ffmpeg_not_available}

      ffmpeg ->
        offset_str = :erlang.float_to_binary(max(offset_seconds, 0.0) * 1.0, decimals: 3)

        args = [
          "-ss",
          offset_str,
          "-i",
          file_path,
          "-frames:v",
          "1",
          "-f",
          "image2pipe",
          "-vcodec",
          "mjpeg",
          "pipe:1"
        ]

        case System.cmd(ffmpeg, args, stderr_to_stdout: false, into: []) do
          {chunks, 0} ->
            jpeg = IO.iodata_to_binary(chunks)

            if byte_size(jpeg) > 0 do
              {:ok, jpeg}
            else
              {:error, :empty_poster_frame}
            end

          {_output, code} ->
            {:error, {:ffmpeg_failed, code}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_ffprobe_output(json_str) do
    case Jason.decode(json_str) do
      {:ok, data} -> {:ok, build_metadata(data)}
      {:error, reason} -> {:error, {:json_parse_failed, reason}}
    end
  end

  defp build_metadata(data) do
    streams = Map.get(data, "streams", [])
    format = Map.get(data, "format", %{})
    video_stream = Enum.find(streams, &(Map.get(&1, "codec_type") == "video"))
    audio_stream = Enum.find(streams, &(Map.get(&1, "codec_type") == "audio"))

    %{}
    |> put_duration(format, video_stream)
    |> put_bit_rate(format)
    |> put_video_fields(video_stream)
    |> put_audio_fields(audio_stream)
  end

  defp put_duration(meta, format, video_stream) do
    raw = Map.get(format, "duration") || Map.get(video_stream || %{}, "duration")

    case parse_float(raw) do
      nil -> meta
      dur -> Map.put(meta, "duration", dur)
    end
  end

  defp put_bit_rate(meta, format) do
    case parse_integer(Map.get(format, "bit_rate")) do
      nil -> meta
      br -> Map.put(meta, "bit_rate", br)
    end
  end

  defp put_video_fields(meta, nil), do: meta

  defp put_video_fields(meta, stream) do
    meta
    |> maybe_put("width", Map.get(stream, "width"))
    |> maybe_put("height", Map.get(stream, "height"))
    |> maybe_put("codec", Map.get(stream, "codec_name"))
    |> maybe_put("fps", parse_frame_rate(Map.get(stream, "r_frame_rate")))
  end

  defp put_audio_fields(meta, nil), do: meta

  defp put_audio_fields(meta, stream) do
    maybe_put(meta, "audio_codec", Map.get(stream, "codec_name"))
  end

  # Parse rational frame-rate strings like "30/1" or "2997/100" into a float.
  defp parse_frame_rate(nil), do: nil

  defp parse_frame_rate(str) when is_binary(str) do
    case String.split(str, "/") do
      [num_str, den_str] ->
        with {num, ""} <- Integer.parse(num_str),
             {den, ""} <- Integer.parse(den_str),
             true <- den != 0 do
          Float.round(num / den, 3)
        else
          _ -> nil
        end

      _ ->
        parse_float(str)
    end
  end

  defp parse_frame_rate(_), do: nil

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(v) when is_integer(v), do: v

  defp parse_integer(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
