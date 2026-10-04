# Error handling

PhxMediaLibrary uses tagged tuples for all operations that can fail, and provides
structured exception types with metadata for programmatic error handling.

## Tagged tuples

All fallible functions return `{:ok, result}` or `{:error, reason}`:

```elixir
case PhxMediaLibrary.to_collection(adder, :images) do
  {:ok, media} ->
    # Success: media was stored and persisted

  {:error, :invalid_mime_type} ->
    # File type not accepted by collection's :accepts list

  {:error, {:file_too_large, actual_size, max_size}} ->
    # File exceeds collection's :max_size limit

  {:error, :content_type_mismatch} ->
    # File content doesn't match declared MIME type (magic bytes check)

  {:error, :file_not_found} ->
    # Source file doesn't exist on disk

  {:error, changeset} ->
    # Ecto validation error, inspect changeset.errors for details
end
```

### Bang versions

Functions that return tagged tuples have `!` bang counterparts that raise on
error:

```elixir
# Returns {:ok, media} or {:error, reason}
{:ok, media} = PhxMediaLibrary.to_collection(adder, :images)

# Raises PhxMediaLibrary.Error on failure
media = PhxMediaLibrary.to_collection!(adder, :images)
```

## Common error reasons

| Error | When it occurs |
|-------|---------------|
| `{:invalid_mime_type, detected, accepts}` | The file's type is not in the collection's `:accepts` list |
| `{:file_too_large, actual, max}` | The file exceeds the collection's `:max_size` (also from `presigned_upload/3` for a declared `:size`) |
| `{:content_type_mismatch, detected, declared}` | The content doesn't match the type its extension declares |
| `{:image_too_large, pixels, max}` | The image has more pixels than `:max_pixels` allows |
| `{:download_failed, reason}` | `add_from_url/3` couldn't fetch the file |
| `:not_found` | The media record, or a direct upload's stored object, doesn't exist |
| `{:partial, saved, failed}` | Some uploads in `consume_media/5` failed; `saved` were stored |
| `%Ecto.Changeset{}` | Database validation failure |

## Custom exception types

PhxMediaLibrary provides three structured exception types, each with fields
designed for programmatic handling, logging, and user-facing messages.

### `PhxMediaLibrary.Error`

The base exception for general errors:

```elixir
%PhxMediaLibrary.Error{
  message: "something went wrong",
  reason: :invalid_source,
  metadata: %{}
}
```

| Field | Type | Description |
|-------|------|-------------|
| `:message` | `String.t()` | Human-readable error description |
| `:reason` | `atom()` | Machine-readable error identifier |
| `:metadata` | `map()` | Additional context |

### `PhxMediaLibrary.StorageError`

Raised when a storage backend operation fails:

```elixir
%PhxMediaLibrary.StorageError{
  message: "failed to write file",
  operation: :put,
  path: "posts/42/<uuid>/posts_42_images_<uuid>.jpg",
  adapter: PhxMediaLibrary.Storage.Disk
}
```

| Field | Type | Description |
|-------|------|-------------|
| `:message` | `String.t()` | Human-readable error description |
| `:operation` | `atom()` | The storage operation that failed (`:put`, `:get`, `:delete`, `:exists?`, `:url`) |
| `:path` | `String.t()` | The storage path involved |
| `:adapter` | `module()` | The storage adapter that raised the error |

### `PhxMediaLibrary.ValidationError`

Raised when a pre-storage validation fails. Automatically formats file sizes in
human-readable units:

```elixir
%PhxMediaLibrary.ValidationError{
  message: "File size 15.0 MB exceeds maximum of 10.0 MB",
  field: :size,
  value: 15_000_000,
  constraint: 10_000_000
}
```

| Field | Type | Description |
|-------|------|-------------|
| `:message` | `String.t()` | Human-readable description (auto-formatted for sizes) |
| `:field` | `atom()` | The field that failed validation (`:size`, `:mime_type`, `:content_type`) |
| `:value` | `term()` | The actual value that was rejected |
| `:constraint` | `term()` | The constraint that was violated |

### Rescuing exceptions

```elixir
try do
  PhxMediaLibrary.to_collection!(adder, :images)
rescue
  e in PhxMediaLibrary.ValidationError ->
    Logger.warning("Validation failed on #{e.field}: #{e.message}")

  e in PhxMediaLibrary.StorageError ->
    Logger.error("Storage #{e.operation} failed for #{e.path}: #{e.message}")

  e in PhxMediaLibrary.Error ->
    Logger.error("Media error: #{e.message} (#{e.reason})")
end
```

## Content-based MIME detection

PhxMediaLibrary uses magic-bytes inspection to verify uploaded files are what
they claim to be. This prevents attacks like renaming an executable to `.jpg`.

### How it works

1. The detector reads the first bytes of the file content
2. It matches against known magic byte signatures (50+ formats)
3. If a match is found, that becomes the detected MIME type
4. If no match, it falls back to extension-based detection
5. If `:verify_content_type` is `true` (the default), it compares the detected
   type to the declared type and rejects any mismatch

### Supported format categories

- **Images.** JPEG, PNG, GIF, WebP, BMP, TIFF, ICO, SVG, AVIF, HEIC, and more
- **Documents.** PDF, Office formats (docx, xlsx, pptx), RTF
- **Audio.** MP3, WAV, FLAC, OGG, AAC, MIDI
- **Video.** MP4, WebM, AVI, MKV, MOV
- **Archives.** ZIP, GZIP, TAR, RAR, 7z, BZIP2, XZ, ZSTD
- **Executables.** ELF, Mach-O, PE/EXE (detected and rejectable)

### Disabling verification

Per-collection:

```elixir
collection :raw_uploads, verify_content_type: false
```

Globally:

```elixir
config :phx_media_library,
  verify_content_type: false
```

### Custom detector

Implement the `PhxMediaLibrary.MimeDetector` behaviour to provide your own
detection logic:

```elixir
defmodule MyApp.MimeDetector do
  @behaviour PhxMediaLibrary.MimeDetector

  @impl true
  def detect(content, filename) do
    # Your custom detection logic
    {:ok, "application/octet-stream"}
  end
end

# config/config.exs
config :phx_media_library,
  mime_detector: MyApp.MimeDetector
```

The callback receives the raw binary content (at least the first few KB) and the
original filename, and must return `{:ok, mime_type}` or
`{:error, :unrecognized}`.