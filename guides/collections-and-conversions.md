# Collections & Conversions

Collections organize your media into named groups with validation rules.
Conversions automatically generate derived images (thumbnails, previews, etc.)
when media is added.

## Collections

Define collections in your Ecto schema using the declarative DSL or
function-based approach:

```elixir
media_collections do
  # Basic collection
  collection :images

  # MIME type validation
  collection :documents, accepts: ~w(application/pdf application/msword)

  # Single file only (replaces existing on new upload)
  collection :avatar, single_file: true

  # Limit number of files (oldest excess is removed)
  collection :gallery, max_files: 10

  # Maximum file size (in bytes — 10 MB here)
  collection :uploads, max_size: 10_000_000

  # Disable content-type verification (enabled by default)
  collection :misc, verify_content_type: false

  # Custom storage disk
  collection :backups, disk: :s3

  # Fallback URL when collection is empty
  collection :profile_photo, single_file: true, fallback_url: "/images/default-avatar.png"
end
```

### Collection Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:accepts` | `[String.t()]` | `nil` (all types) | Allowed MIME types |
| `:single_file` | `boolean()` | `false` | Keep only one file; new upload replaces existing |
| `:max_files` | `pos_integer()` | `nil` (unlimited) | Maximum number of files; oldest excess is removed |
| `:max_size` | `pos_integer()` | `nil` (unlimited) | Maximum file size in bytes |
| `:disk` | `atom()` | configured default | Storage disk override |
| `:fallback_url` | `String.t()` | `nil` | URL returned when collection is empty |
| `:fallback_path` | `String.t()` | `nil` | Filesystem path returned when collection is empty |
| `:verify_content_type` | `boolean()` | `true` | Verify file content matches declared MIME type via magic bytes |

### Content-Type Verification

By default, PhxMediaLibrary inspects the first bytes of every uploaded file
(magic bytes) to detect the real MIME type. If the detected type doesn't match
the declared content type, the upload is rejected with
`{:error, :content_type_mismatch}`. This covers 50+ formats including images,
documents, audio, video, and archives.

You can disable this per-collection:

```elixir
collection :raw_uploads, verify_content_type: false
```

Or provide a custom detector globally by implementing the
`PhxMediaLibrary.MimeDetector` behaviour:

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

### File Size Validation

The `:max_size` option rejects files before they reach storage. When used with
LiveView, `allow_media_upload/3` automatically derives the `:max_file_size`
upload option from the collection configuration.

```elixir
collection :photos, max_size: 5_000_000, accepts: ~w(image/jpeg image/png)
```

If a file exceeds the limit, you'll get:

```elixir
{:error, {:file_too_large, actual_size, max_size}}
```

## Conversions

Conversions automatically generate derived images when media is added. They
require the `:image` dependency (libvips).

> **Important:** Always scope conversions to the collections they apply to.
> Without scoping, a conversion runs for **every** collection — including
> non-image collections like documents, which will cause processing errors.
> The nested syntax (recommended) handles this automatically. The flat syntax
> requires an explicit `:collections` option on each conversion.

### Nested Conversions (Recommended)

The clearest way to define conversions is inside a `collection ... do ... end`
block. Each conversion is automatically scoped to the enclosing collection —
no need to pass `:collections` manually. Collections without image content
(like `:documents`) simply omit the `do` block, so no conversions will ever
run for those uploads:

```elixir
media_collections do
  collection :images, max_files: 20 do
    convert :thumb, width: 150, height: 150, fit: :cover
    convert :preview, width: 800, quality: 85
    convert :banner, width: 1200, height: 400, fit: :crop
  end

  # No conversions for documents — just omit the do block
  collection :documents, accepts: ~w(application/pdf text/plain)

  collection :avatar, single_file: true do
    convert :thumb, width: 150, height: 150, fit: :cover
  end
end
```

In this example:
- `:thumb`, `:preview`, and `:banner` only run for `:images` uploads
- `:thumb` also runs for `:avatar` uploads (defined separately in that block)
- Nothing runs for `:documents` — PDFs are stored as-is

### Flat Conversions

You can also define conversions in a separate `media_conversions` block.
**Always use the `:collections` option** to scope each conversion explicitly:

```elixir
media_collections do
  collection :images, max_files: 20
  collection :documents, accepts: ~w(application/pdf text/plain)
  collection :avatar, single_file: true
end

media_conversions do
  # Scoped to specific collections — always recommended
  convert :thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]
  convert :preview, width: 800, quality: 85, collections: [:images]
  convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
end
```

Or with the function-based approach:

```elixir
def media_conversions do
  [
    conversion(:thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]),
    conversion(:preview, width: 800, quality: 85, collections: [:images]),
    conversion(:banner, width: 1200, height: 400, fit: :crop, collections: [:images])
  ]
end
```

### Mixing Nested and Flat Styles

You can combine both approaches. Use nested conversions for collection-specific
transforms and a `media_conversions` block for anything else:

```elixir
media_collections do
  collection :images, max_files: 20 do
    convert :preview, width: 800, quality: 85
    convert :banner, width: 1200, height: 400, fit: :crop
  end

  collection :documents, accepts: ~w(application/pdf)

  collection :avatar, single_file: true
end

media_conversions do
  # Shared thumbnail for images and avatar
  convert :thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]
end
```

### Conversion Options

```elixir
convert :name,
  width: 150,              # Target width in pixels
  height: 150,             # Target height in pixels
  fit: :cover,             # Resize strategy (see table below)
  quality: 85,             # JPEG/WebP quality (1-100)
  format: :webp,           # Output format (:jpg, :png, :webp)
  collections: [:images]   # Only apply to these collections
```

### Fit Options

| Mode | Behaviour |
|------|-----------|
| `:contain` | Fit within dimensions, maintaining aspect ratio |
| `:cover` | Cover dimensions, cropping if necessary |
| `:fill` | Stretch to fill dimensions exactly |
| `:crop` | Crop to exact dimensions from center |

### Triggering Conversions Explicitly

Conversions run automatically when media is added. You can also request specific
conversions during the add pipeline:

```elixir
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.with_conversions([:thumb, :preview])
|> PhxMediaLibrary.to_collection(:images)
```

### Regenerating Conversions

If you change conversion definitions, regenerate existing media:

```bash
mix phx_media_library.regenerate --conversion thumb
mix phx_media_library.regenerate --collection images
mix phx_media_library.regenerate --dry-run
```

## Checksum & Integrity Verification

SHA-256 checksums are computed automatically during upload and stored alongside
each media record.

```elixir
# Verify a file hasn't been tampered with or corrupted
case PhxMediaLibrary.verify_integrity(media) do
  :ok -> IO.puts("File is intact")
  {:error, :checksum_mismatch} -> IO.puts("File has been corrupted!")
  {:error, :no_checksum} -> IO.puts("No checksum stored for this media")
end
```

## Responsive Images

Generate multiple sizes for optimal loading across devices.

```elixir
# Enable when adding media
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.with_responsive_images()
|> PhxMediaLibrary.to_collection(:images)

# Get srcset attribute
PhxMediaLibrary.srcset(media)
# => "uploads/posts/1/responsive/image-320.jpg 320w, ..."
```

Configure responsive image widths globally:

```elixir
config :phx_media_library,
  responsive_images: [
    enabled: true,
    widths: [320, 640, 960, 1280, 1920],
    tiny_placeholder: true
  ]
```

Regenerate responsive images for existing media:

```bash
mix phx_media_library.regenerate_responsive
mix phx_media_library.regenerate_responsive --collection images
```

See the [LiveView guide](liveview.md) for rendering responsive images with the
`<.responsive_img>` and `<.picture>` components.