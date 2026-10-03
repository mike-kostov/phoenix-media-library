defmodule PhxMediaLibrary.MimeDetector do
  @moduledoc """
  Behaviour and default implementation for content-based MIME type detection.

  PhxMediaLibrary uses this module to detect MIME types from file content
  (magic bytes) rather than relying solely on file extensions. This provides
  a security layer against files with mismatched extensions (e.g. an executable
  renamed to `.jpg`).

  ## How It Works

  1. The detector reads the first bytes of the file content
  2. It matches against known magic byte signatures
  3. If a match is found, that becomes the detected MIME type
  4. If no match is found, it falls back to extension-based detection

  ## Custom Implementation

  You can provide your own detector by implementing the behaviour and
  configuring it:

      defmodule MyApp.MimeDetector do
        @behaviour PhxMediaLibrary.MimeDetector

        @impl true
        def detect(content, filename) do
          # Your custom detection logic
          {:ok, "application/octet-stream"}
        end
      end

      config :phx_media_library,
        mime_detector: MyApp.MimeDetector

  ## Configuration

  The default detector can be configured to skip verification:

      # Disable content-type verification globally
      config :phx_media_library,
        verify_content_type: false

  Or per-collection:

      collection(:uploads, verify_content_type: false)

  """

  @typedoc """
  Result of MIME type detection.

  - `{:ok, mime_type}` — a MIME type was successfully detected
  - `{:error, :unrecognized}` — the content didn't match any known signature
  """
  @type detection_result :: {:ok, String.t()} | {:error, :unrecognized}

  @doc """
  Detect the MIME type of file content.

  Receives the raw binary content (or at least the first few KB) and the
  original filename. Implementations should primarily use the content for
  detection and may use the filename as a fallback.

  Returns `{:ok, mime_type}` if a type was detected, or
  `{:error, :unrecognized}` if the content didn't match any known signature.
  """
  @callback detect(content :: binary(), filename :: String.t()) :: detection_result()

  @doc """
  Detect the MIME type from binary content using magic byte signatures.

  Uses the configured detector module, falling back to the built-in
  magic bytes implementation.

  ## Examples

      iex> png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "rest of file">>
      iex> PhxMediaLibrary.MimeDetector.detect(png_header, "photo.png")
      {:ok, "image/png"}

      iex> PhxMediaLibrary.MimeDetector.detect("just some text", "notes.txt")
      {:error, :unrecognized}

  """
  @spec detect(binary(), String.t()) :: detection_result()
  def detect(content, filename) do
    detector = Application.get_env(:phx_media_library, :mime_detector, __MODULE__.Default)
    detector.detect(content, filename)
  end

  @doc """
  Detect the MIME type and verify it matches the declared type.

  Returns `:ok` if the detected type matches or if detection is inconclusive
  (falls back to trusting the declared type). Returns
  `{:error, {:content_type_mismatch, detected, declared}}` if the content
  clearly doesn't match the declared type.

  Compatible types are not a mismatch:

    * the same family — `image/*`, `audio/*`, `video/*` (a PNG saved as
      `.jpg`, `audio/wav` vs `audio/x-wav`). SVG is the exception: it can
      carry scripts, so it only matches SVG.
    * ZIP content declared as a ZIP-based format (`.docx`, `.xlsx`, `.odt`,
      `.epub`, ...)
    * `application/xml` vs `text/xml`
    * an unknown declared type (`application/octet-stream`)

  A file whose bytes are an image but whose extension says `.html` is still
  rejected — that is the case that matters, since the extension decides how
  the file is served.

  ## Parameters

  - `content` — the raw binary file content (or its first few KB)
  - `filename` — the original filename
  - `declared_mime` — the MIME type declared by the file extension or upload metadata

  ## Examples

      iex> png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "rest">>
      iex> PhxMediaLibrary.MimeDetector.verify(png_header, "photo.png", "image/png")
      :ok

      iex> png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "rest">>
      iex> PhxMediaLibrary.MimeDetector.verify(png_header, "fake.exe", "application/x-msdownload")
      {:error, {:content_type_mismatch, "image/png", "application/x-msdownload"}}

      iex> png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "rest">>
      iex> PhxMediaLibrary.MimeDetector.verify(png_header, "page.html", "text/html")
      {:error, {:content_type_mismatch, "image/png", "text/html"}}

      iex> png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "rest">>
      iex> PhxMediaLibrary.MimeDetector.verify(png_header, "photo.jpg", "image/jpeg")
      :ok

  """
  @spec verify(binary(), String.t(), String.t()) ::
          :ok | {:error, {:content_type_mismatch, String.t(), String.t()}}
  def verify(content, filename, declared_mime) do
    case detect(content, filename) do
      {:ok, detected_mime} ->
        if mime_types_match?(detected_mime, declared_mime) do
          :ok
        else
          {:error, {:content_type_mismatch, detected_mime, declared_mime}}
        end

      {:error, :unrecognized} ->
        # Can't detect from content — trust the declared type
        :ok
    end
  end

  @doc """
  Detect the MIME type from content, falling back to extension-based detection.

  Unlike `detect/2`, this always returns a MIME type string — it falls back
  to `MIME.from_path/1` when magic bytes don't match.

  ## Examples

      iex> png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "rest">>
      iex> PhxMediaLibrary.MimeDetector.detect_with_fallback(png_header, "photo.png")
      "image/png"

      iex> PhxMediaLibrary.MimeDetector.detect_with_fallback("unknown content", "data.csv")
      "text/csv"

  """
  @spec detect_with_fallback(binary(), String.t()) :: String.t()
  def detect_with_fallback(content, filename) do
    case detect(content, filename) do
      {:ok, mime_type} -> mime_type
      {:error, :unrecognized} -> MIME.from_path(filename)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: MIME type comparison
  # ---------------------------------------------------------------------------

  # ZIP containers that MIME.from_path/1 reports under their own type.
  @zip_based_prefixes [
    "application/vnd.openxmlformats-officedocument.",
    "application/vnd.oasis.opendocument.",
    "application/vnd.ms-",
    "application/epub+zip",
    "application/java-archive",
    "application/vnd.android.package-archive",
    "application/x-zip-compressed"
  ]

  @media_families ["image", "audio", "video"]
  @svg "image/svg+xml"

  # Check if two MIME types are compatible — see verify/3 for the rules.
  defp mime_types_match?(detected, declared) do
    detected = normalize_mime(detected)
    declared = normalize_mime(declared)
    [detected_family | _] = String.split(detected, "/")

    cond do
      detected == declared -> true
      declared == "application/octet-stream" -> true
      @svg in [detected, declared] -> false
      detected_family in @media_families -> String.starts_with?(declared, detected_family <> "/")
      detected == "application/zip" -> String.starts_with?(declared, @zip_based_prefixes)
      true -> xml?(detected) and xml?(declared)
    end
  end

  defp xml?(mime), do: mime in ["application/xml", "text/xml"]

  defp normalize_mime(mime) do
    mime
    |> String.downcase()
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end
end
