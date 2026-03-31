defmodule PhxMediaLibrary.VideoProcessor do
  @moduledoc """
  Behaviour for video processing adapters.

  PhxMediaLibrary uses video processors to extract metadata (duration,
  codec, fps, dimensions) and generate poster frames from video files.

  ## Built-in Adapters

    * `PhxMediaLibrary.VideoProcessor.FFmpeg` — uses `ffprobe` and `ffmpeg`
      system executables. Selected automatically when both are on `$PATH`.
    * `PhxMediaLibrary.VideoProcessor.Null` — no-op fallback used when
      FFmpeg is not installed. Metadata extraction and poster generation
      return error tuples; uploads still succeed without metadata or poster
      frames.

  ## Auto-detection

  No configuration is needed in the common case. The library checks for
  `ffprobe` and `ffmpeg` on `$PATH` at startup and selects the appropriate
  adapter automatically via `PhxMediaLibrary.Config.video_processor/0`.

  ## Custom Adapters

  Implement this behaviour and set in config:

      defmodule MyApp.VideoProcessor do
        @behaviour PhxMediaLibrary.VideoProcessor

        @impl true
        def available?, do: true

        @impl true
        def extract_metadata(file_path) do
          {:ok, %{"duration" => 10.5, "codec" => "h264", "fps" => 30.0}}
        end

        @impl true
        def extract_poster(file_path, offset_seconds) do
          {:ok, jpeg_binary}
        end
      end

      config :phx_media_library,
        video_processor: MyApp.VideoProcessor

  """

  @doc """
  Returns `true` when the underlying tool or library is available on the
  current system.
  """
  @callback available?() :: boolean()

  @doc """
  Extract metadata from a video file.

  Returns `{:ok, metadata}` where `metadata` is a map that may include:

    * `"duration"` — total duration in seconds (float)
    * `"width"` / `"height"` — video stream dimensions (integer)
    * `"codec"` — video codec name, e.g. `"h264"` (string)
    * `"fps"` — frames per second (float)
    * `"audio_codec"` — audio codec name, e.g. `"aac"` (string, optional)
    * `"bit_rate"` — overall bit rate in bits/s (integer, optional)

  Returns `{:error, reason}` when extraction fails. Extraction failures are
  **non-fatal** — the upload proceeds with whatever metadata was already
  collected.
  """
  @callback extract_metadata(file_path :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Extract a poster frame (JPEG binary) from a video file.

  `offset_seconds` is the time offset at which to capture the frame.
  Implementations should clamp this value to a valid range for the file.

  Returns `{:ok, jpeg_binary}` on success, or `{:error, reason}` on failure.
  """
  @callback extract_poster(file_path :: String.t(), offset_seconds :: float()) ::
              {:ok, binary()} | {:error, term()}
end
