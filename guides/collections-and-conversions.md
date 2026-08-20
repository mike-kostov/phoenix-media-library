# Collections & conversions

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

  # Maximum file size in bytes (10 MB here)
  collection :uploads, max_size: 10_000_000

  # Disable content-type verification (enabled by default)
  collection :misc, verify_content_type: false

  # Custom storage disk
  collection :backups, disk: :s3

  # Fallback URL when collection is empty
  collection :profile_photo, single_file: true, fallback_url: "/images/default-avatar.png"
end
```

### Collection options

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
| `:webp` | `boolean() \| keyword()` | inherits global | Transcode raster/HEIC uploads to WebP and serve them ([WebP Conversion](#webp-conversion)) |
| `:responsive` | `boolean() \| keyword()` | inherits global | Generate multi-width `srcset` variants on add ([Responsive Images](#responsive-images)) |

### Content-Type verification

By default, PhxMediaLibrary inspects the first bytes of every uploaded file
(magic bytes) to detect the real MIME type. If the detected type doesn't match
the declared content type, PhxMediaLibrary rejects the upload with
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

### File size validation

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
> Without scoping, a conversion runs for every collection, including
> non-image collections like documents, which causes processing errors.
> The nested syntax (recommended) handles this automatically. The flat syntax
> requires an explicit `:collections` option on each conversion.

### Nested conversions (recommended)

The clearest way to define conversions is inside a `collection ... do ... end`
block. Each conversion is automatically scoped to the enclosing collection, so
there's no need to pass `:collections` manually. Collections without image content
(like `:documents`) omit the `do` block, so no conversions run for those uploads:

```elixir
media_collections do
  collection :images, max_files: 20 do
    convert :thumb, width: 150, height: 150, fit: :cover
    convert :preview, width: 800, quality: 85
    convert :banner, width: 1200, height: 400, fit: :crop
  end

  # No conversions for documents, just omit the do block
  collection :documents, accepts: ~w(application/pdf text/plain)

  collection :avatar, single_file: true do
    convert :thumb, width: 150, height: 150, fit: :cover
  end
end
```

In this example:
- `:thumb`, `:preview`, and `:banner` only run for `:images` uploads
- `:thumb` also runs for `:avatar` uploads (defined separately in that block)
- Nothing runs for `:documents`. PDFs are stored as-is

### Flat conversions

You can also define conversions in a separate `media_conversions` block.
**Always use the `:collections` option** to scope each conversion explicitly:

```elixir
media_collections do
  collection :images, max_files: 20
  collection :documents, accepts: ~w(application/pdf text/plain)
  collection :avatar, single_file: true
end

media_conversions do
  # Scoped to specific collections, always recommended
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

### Mixing nested and flat styles

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

### Conversion options

```elixir
convert :name,
  width: 150,              # Target width in pixels
  height: 150,             # Target height in pixels
  fit: :cover,             # Resize strategy (see table below)
  quality: 85,             # JPEG/WebP quality (1-100)
  format: :webp,           # Output format (:jpg, :png, :webp)
  collections: [:images]   # Only apply to these collections
```

### Fit options

| Mode | Behaviour |
|------|-----------|
| `:contain` | Fit within dimensions, maintaining aspect ratio |
| `:cover` | Cover dimensions, cropping if necessary |
| `:fill` | Stretch to fill dimensions exactly |
| `:crop` | Crop to exact dimensions from center |

### Triggering conversions explicitly

Conversions run automatically when media is added. You can also request specific
conversions during the add pipeline:

```elixir
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.with_conversions([:thumb, :preview])
|> PhxMediaLibrary.to_collection(:images)
```

### Regenerating conversions

If you change conversion definitions, regenerate existing media:

```bash
mix phx_media_library.regenerate --conversion thumb
mix phx_media_library.regenerate --collection images
mix phx_media_library.regenerate --dry-run
```

## Checksum & integrity verification

PhxMediaLibrary computes a SHA-256 checksum during upload and stores it alongside
each media record.

```elixir
# Verify a file hasn't been tampered with or corrupted
case PhxMediaLibrary.verify_integrity(media) do
  :ok -> IO.puts("File is intact")
  {:error, :checksum_mismatch} -> IO.puts("File has been corrupted!")
  {:error, :no_checksum} -> IO.puts("No checksum stored for this media")
end
```

## WebP conversion

Transcode raster and HEIC/HEIF uploads to WebP for faster loads and better SEO.
Unlike a `format: :webp` conversion (which produces a *named* derivative), this
keeps the original and serves a co-located WebP automatically, so `<img src>` needs
no change. Requires the `:image` (libvips) dependency; it no-ops when
libvips is absent or the source isn't raster.

Enable it per collection. `true` inherits the global config; a keyword overrides
individual knobs:

```elixir
media_collections do
  collection :photos, webp: true                          # jpg/png/HEIC → served as WebP
  collection :hero,   webp: [quality: 90, keep_original: false]
end
```

Or turn it on globally (each knob overridable per collection):

```elixir
config :phx_media_library,
  webp: [enabled: false, quality: 82, keep_original: true]
```

| Knob | Default | Description |
|------|---------|-------------|
| `:enabled` | `false` | Generate + serve WebP for the collection (implied by `webp: true`) |
| `:quality` | `82` | WebP encoder quality (1-100) |
| `:keep_original` | `true` | Keep the source file; `false` deletes it after conversions run |

Behaviour when WebP is on:

- On add, the original is kept as `media.file_name` and a `.webp` sibling is
  generated in the same folder. URL helpers (`url/2`, `get_first_media_url/3`)
  return the WebP via `custom_properties["webp"]`; they fall back to the original
  when libvips is unavailable.
- `keep_original: false` removes the source, but only after all conversions
  (and responsive variants) have been derived from it. Deletion is strictly the
  last step, so it is safe to combine with named conversions.
- **HEIC/HEIF** (e.g. iPhone uploads): add `image/heic`/`image/heif` to
  `:accepts`; libvips decodes them and the served WebP is browser-viewable while
  the original HEIC is kept.

Regenerate WebP from each media's original after changing `quality` (or after
enabling WebP on existing media):

```bash
mix phx_media_library.regenerate_webp
mix phx_media_library.regenerate_webp --collection photos --dry-run
```

> Regeneration reads the original, which is why `keep_original: true` is the
> default. Media stored with `keep_original: false` have no source and are
> skipped with a warning.

## Responsive images

Generate multiple sizes so browsers download an appropriately-sized image via
`srcset`. Enable it per collection (the recommended path). `true` inherits
the global widths, a keyword overrides them:

```elixir
media_collections do
  collection :photos,  webp: true, responsive: true                  # WebP srcset, global widths
  collection :banners, webp: true, responsive: [widths: [640, 1280, 2560]]
end
```

When a collection also serves WebP, its responsive variants are WebP-encoded
and the full-size `srcset` descriptor reuses the existing WebP sibling, so the
whole `srcset` is WebP at no extra cost. Otherwise variants keep the source
format.

You can also request variants ad hoc for a single upload:

```elixir
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.with_responsive_images()
|> PhxMediaLibrary.to_collection(:images)

PhxMediaLibrary.srcset(media)
# => "…/responsive/image_320w.webp 320w, …/responsive/image_640w.webp 640w, …"
```

Configure the default widths (and placeholder) globally. This global
`:enabled` supplies defaults but does not auto-generate variants for every
collection. Generation is opt-in via the per-collection `:responsive` flag (or
`with_responsive_images/1`):

```elixir
config :phx_media_library,
  responsive_images: [
    enabled: true,
    widths: [320, 640, 960, 1280, 1920],
    tiny_placeholder: true
  ]
```

Regenerate responsive variants for existing media (WebP-encoded when the media
already serves WebP):

```bash
mix phx_media_library.regenerate_responsive
mix phx_media_library.regenerate_responsive --collection photos
```

See the [LiveView guide](liveview.md) for rendering responsive images with the
`<.responsive_img>` and `<.picture>` components.