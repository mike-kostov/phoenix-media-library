defmodule PhxMediaLibrary.VideoProcessor.Null do
  @moduledoc """
  No-op video processor used when FFmpeg is not available.

  All operations return error tuples rather than raising. Uploads still
  succeed and files are stored and served — metadata extraction and poster
  frame generation are simply skipped.

  To enable video processing, install FFmpeg:

      # macOS
      brew install ffmpeg

      # Ubuntu / Debian
      apt-get install ffmpeg

  Once installed, `PhxMediaLibrary.VideoProcessor.FFmpeg` is selected
  automatically on the next application start (no configuration required).
  """

  @behaviour PhxMediaLibrary.VideoProcessor

  @impl true
  @doc "Always returns `false` — FFmpeg is not available."
  @spec available?() :: boolean()
  def available?, do: false

  @impl true
  @doc "Returns `{:error, :ffmpeg_not_available}`."
  @spec extract_metadata(String.t()) :: {:error, :ffmpeg_not_available}
  def extract_metadata(_file_path), do: {:error, :ffmpeg_not_available}

  @impl true
  @doc "Returns `{:error, :ffmpeg_not_available}`."
  @spec extract_poster(String.t(), float()) :: {:error, :ffmpeg_not_available}
  def extract_poster(_file_path, _offset_seconds \\ 0.0), do: {:error, :ffmpeg_not_available}
end
