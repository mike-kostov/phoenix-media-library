defmodule PhxMediaLibrary.MetadataExtractor do
  @moduledoc """
  Behaviour and default implementation for extracting file metadata.

  PhxMediaLibrary automatically extracts metadata from uploaded files and
  stores it in the `metadata` field of the `Media` schema. This includes
  image dimensions, video/audio duration, EXIF data, and more.

  ## Extracted Metadata

  The metadata map may contain the following keys depending on file type:

  ### Images

  - `"width"` — image width in pixels
  - `"height"` — image height in pixels
  - `"format"` — detected image format (e.g. `"jpeg"`, `"png"`, `"webp"`)
  - `"exif"` — EXIF data map (orientation, camera make/model, GPS, etc.)
  - `"has_alpha"` — whether the image has an alpha channel

  ### Video

  - `"width"` — video width in pixels
  - `"height"` — video height in pixels
  - `"duration"` — duration in seconds (float)
  - `"format"` — container format (e.g. `"mp4"`, `"webm"`)

  ### Audio

  - `"duration"` — duration in seconds (float)
  - `"format"` — audio format (e.g. `"mp3"`, `"wav"`, `"flac"`)

  ### All files

  - `"extracted_at"` — ISO 8601 timestamp of when metadata was extracted

  ## Custom Implementation

  You can provide your own extractor by implementing the behaviour and
  configuring it:

      defmodule MyApp.MetadataExtractor do
        @behaviour PhxMediaLibrary.MetadataExtractor

        @impl true
        def extract(file_path, mime_type, _opts) do
          # Your custom extraction logic
          {:ok, %{"custom_field" => "value"}}
        end
      end

      config :phx_media_library,
        metadata_extractor: MyApp.MetadataExtractor

  ## Disabling Extraction

  To disable automatic metadata extraction:

      config :phx_media_library,
        extract_metadata: false

  Or per-call:

      post
      |> PhxMediaLibrary.add(upload)
      |> PhxMediaLibrary.without_metadata()
      |> PhxMediaLibrary.to_collection(:images)

  """

  @typedoc """
  Result of metadata extraction.

  - `{:ok, metadata}` — metadata was successfully extracted
  - `{:error, reason}` — extraction failed (non-fatal; upload still proceeds)
  """
  @type extraction_result :: {:ok, map()} | {:error, term()}

  @doc """
  Extract metadata from a file.

  Receives the file path, MIME type, and optional keyword options.
  Returns `{:ok, metadata_map}` or `{:error, reason}`.

  Extraction failures are **non-fatal** — the upload will still proceed
  with an empty metadata map. This ensures that missing system libraries
  (e.g. libvips not installed) don't break file uploads.
  """
  @callback extract(file_path :: String.t(), mime_type :: String.t(), opts :: keyword()) ::
              extraction_result()

  @doc """
  Extract metadata using the configured extractor.

  Falls back to an empty metadata map on any error, logging a warning.

  ## Options

  - `:extractor` — override the extractor module for this call

  ## Examples

      {:ok, metadata} = PhxMediaLibrary.MetadataExtractor.extract_metadata("/path/to/photo.jpg", "image/jpeg")
      metadata["width"]   #=> 1920
      metadata["height"]  #=> 1080

  """
  @spec extract_metadata(String.t(), String.t(), keyword()) :: {:ok, map()}
  def extract_metadata(file_path, mime_type, opts \\ []) do
    extractor = opts[:extractor] || configured_extractor()

    case extractor.extract(file_path, mime_type, opts) do
      {:ok, metadata} when is_map(metadata) ->
        {:ok, Map.put(metadata, "extracted_at", DateTime.utc_now() |> DateTime.to_iso8601())}

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[PhxMediaLibrary] Metadata extraction failed for #{file_path} " <>
            "(#{mime_type}): #{inspect(reason)}"
        )

        {:ok, %{}}
    end
  end

  @doc """
  Check whether automatic metadata extraction is enabled globally.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:phx_media_library, :extract_metadata, true)
  end

  @doc """
  Returns the configured metadata extractor module.
  """
  @spec configured_extractor() :: module()
  def configured_extractor do
    Application.get_env(
      :phx_media_library,
      :metadata_extractor,
      PhxMediaLibrary.MetadataExtractor.Default
    )
  end
end
