defmodule PhxMediaLibrary.MetadataExtractor.Default do
  @moduledoc """
  Default metadata extractor using the `Image` library for images.

  Extracts dimensions, format, alpha channel presence, and EXIF data from
  images when the `:image` library (libvips) is available. For audio and
  video files, extracts basic format information from the MIME type.

  When the `:image` library is not installed, gracefully falls back to
  extracting only basic format information from the MIME type and file
  extension — no error is raised.

  ## Extracted Fields

  ### Images (requires `:image`)

  - `"width"` — width in pixels
  - `"height"` — height in pixels
  - `"format"` — detected format string (e.g. `"jpeg"`, `"png"`, `"webp"`)
  - `"has_alpha"` — boolean, whether the image has an alpha channel
  - `"exif"` — map of EXIF data (when present in the file)

  ### Audio / Video

  - `"format"` — format derived from MIME subtype (e.g. `"mp4"`, `"mp3"`)

  ### All files

  - `"type"` — broad type category: `"image"`, `"video"`, `"audio"`, `"document"`, or `"other"`
  """

  @behaviour PhxMediaLibrary.MetadataExtractor

  @image_library_available Code.ensure_loaded?(Image)

  @impl true
  @spec extract(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def extract(file_path, mime_type, _opts \\ []) do
    type = media_type(mime_type)
    base = %{"type" => type, "format" => format_from_mime(mime_type)}

    metadata =
      case type do
        "image" -> extract_image(file_path, base)
        "video" -> extract_video(file_path, base)
        "audio" -> extract_audio(file_path, base)
        _ -> base
      end

    {:ok, metadata}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Image extraction
  # ---------------------------------------------------------------------------

  if @image_library_available do
    defp extract_image(file_path, base) do
      case Image.open(file_path) do
        {:ok, image} ->
          width = Image.width(image)
          height = Image.height(image)
          has_alpha = Image.has_alpha?(image)

          metadata =
            base
            |> Map.put("width", width)
            |> Map.put("height", height)
            |> Map.put("has_alpha", has_alpha)

          # Extract EXIF data if available
          maybe_put_exif(metadata, image)

        {:error, _reason} ->
          # If Image can't open it (e.g. unsupported format), return base
          base
      end
    end

    defp maybe_put_exif(metadata, image) do
      case Image.exif(image) do
        {:ok, exif} when is_map(exif) and map_size(exif) > 0 ->
          Map.put(metadata, "exif", sanitize_exif(exif))

        _ ->
          metadata
      end
    end

    # Sanitize EXIF data to ensure it's JSON-serializable.
    # EXIF values can contain binaries, tuples, and other non-JSON types.
    defp sanitize_exif(exif) when is_map(exif) do
      Map.new(exif, fn {k, v} -> {to_string(k), sanitize_exif_value(v)} end)
    end

    defp sanitize_exif_value(value) when is_map(value) do
      Map.new(value, fn {k, v} -> {to_string(k), sanitize_exif_value(v)} end)
    end

    defp sanitize_exif_value(value) when is_list(value) do
      Enum.map(value, &sanitize_exif_value/1)
    end

    defp sanitize_exif_value(value) when is_binary(value) do
      if String.valid?(value) do
        value
      else
        Base.encode64(value)
      end
    end

    defp sanitize_exif_value(value) when is_tuple(value) do
      value |> Tuple.to_list() |> Enum.map(&sanitize_exif_value/1)
    end

    defp sanitize_exif_value(value)
         when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value) do
      value
    end

    defp sanitize_exif_value(value) when is_atom(value), do: Atom.to_string(value)

    defp sanitize_exif_value(value), do: inspect(value)
  else
    defp extract_image(_file_path, base), do: base

    # Provide fallback dimensions from the file content if Image is not
    # available. We try to parse PNG and JPEG headers directly.
    # This is a best-effort fallback — not as reliable as libvips.
  end

  # ---------------------------------------------------------------------------
  # Video extraction
  # ---------------------------------------------------------------------------

  # Video metadata extraction beyond format requires external tools
  # (ffprobe, etc.) which are out of scope for the default extractor.
  # Users needing video duration/dimensions should implement a custom
  # extractor using ffprobe or a similar tool.
  defp extract_video(_file_path, base), do: base

  # ---------------------------------------------------------------------------
  # Audio extraction
  # ---------------------------------------------------------------------------

  # Same as video — duration extraction requires ffprobe or similar.
  defp extract_audio(_file_path, base), do: base

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp media_type(mime_type) do
    case String.split(mime_type, "/", parts: 2) do
      ["image", _] -> "image"
      ["video", _] -> "video"
      ["audio", _] -> "audio"
      ["application", subtype] -> document_or_other(subtype)
      ["text", _] -> "document"
      _ -> "other"
    end
  end

  @doc_subtypes ~w(pdf msword rtf vnd.ms-excel vnd.ms-powerpoint)
  @doc_prefixes ~w(vnd.openxmlformats vnd.oasis.opendocument)

  defp document_or_other(subtype) do
    if subtype in @doc_subtypes or
         Enum.any?(@doc_prefixes, &String.starts_with?(subtype, &1)) do
      "document"
    else
      "other"
    end
  end

  defp format_from_mime(mime_type) do
    case String.split(mime_type, "/", parts: 2) do
      [_, subtype] ->
        subtype
        |> String.replace(~r/^x-/, "")
        |> String.replace(~r/^vnd\./, "")
        |> normalize_format()

      _ ->
        "unknown"
    end
  end

  # Normalize common MIME subtypes to friendlier format names
  defp normalize_format("jpeg"), do: "jpeg"
  defp normalize_format("svg+xml"), do: "svg"
  defp normalize_format("plain"), do: "text"
  defp normalize_format("mpeg" <> _), do: "mp3"
  defp normalize_format("mp4"), do: "mp4"
  defp normalize_format("quicktime"), do: "mov"
  defp normalize_format("ms-excel"), do: "xls"
  defp normalize_format("msword"), do: "doc"
  defp normalize_format("octet-stream"), do: "binary"

  defp normalize_format("openxmlformats-officedocument.spreadsheetml.sheet"), do: "xlsx"

  defp normalize_format("openxmlformats-officedocument.wordprocessingml.document"),
    do: "docx"

  defp normalize_format("openxmlformats-officedocument.presentationml.presentation"),
    do: "pptx"

  defp normalize_format(other), do: other
end
