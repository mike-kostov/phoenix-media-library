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

### File naming

The library chooses the name a file is stored under; the uploader's name
is never used in a path. Pick a strategy per collection with
`file_naming:`, or globally with `config :phx_media_library, file_naming:`:

| Strategy | Stored as | For |
|---|---|---|
| `:semantic` (default) | `posts_42_images_<uuid>.jpg` | Rebuilding a lost record from the name alone |
| `:slug` | `red-summer-dress.jpg` | Readable names for search engines; Cyrillic is transliterated (`снимка` becomes `snimka`) |
| `:random` | `k3j5x…q2.jpg` | Names that reveal nothing |

The extension always follows the detected content, so a PNG uploaded as
`photo.jpg` is stored as `.png`. The uploaded name is kept in
`metadata["original_file_name"]`; `Media.alt_text/1` and download URLs use
it. `using_filename/2` replaces that name (and the `:slug` base). Media
stored under other names moves with
`mix phx_media_library.doctor --rename`.

### Collection options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:accepts` | `[String.t()]` | `nil` (all types) | Allowed MIME types |
| `:single_file` | `boolean()` | `false` | Keep only one file; new upload replaces existing |
| `:max_files` | `pos_integer()` | `nil` (unlimited) | Maximum number of files; oldest excess is removed |
| `:max_size` | `pos_integer()` | `nil` (unlimited) | Maximum file size in bytes |
| `:max_pixels` | `pos_integer() \| :infinity` | global `:max_image_pixels` | Largest image accepted, in pixels |
| `:file_naming` | `:semantic \| :slug \| :random` | global `:file_naming`, else `:semantic` | How stored files are named ([File naming](#file-naming)) |
| `:disk` | `atom()` | configured default | Storage disk override |
| `:fallback_url` | `String.t()` | `nil` | URL returned when collection is empty |
| `:fallback_path` | `String.t()` | `nil` | Filesystem path returned when collection is empty |
| `:verify_content_type` | `boolean()` | `true` | Verify file content matches declared MIME type via magic bytes |
| `:webp` | `boolean() \| keyword()` | inherits global | Transcode raster/HEIC uploads to WebP and serve them ([WebP Conversion](#webp-conversion)) |
| `:avif` | `boolean() \| keyword()` | inherits global, off | Add an AVIF beside each image ([AVIF](#avif)) |
| `:placeholder` | `:blur \| :color \| false \| keyword()` | global, else `:blur` | What images show while they load ([Placeholders](#placeholders)) |
| `:responsive` | `boolean() \| keyword()` | inherits global | Generate multi-width `srcset` variants on add ([Responsive Images](#responsive-images)) |
| `:formats` | `[atom() \| {atom(), keyword()}]` | global, else `[:webp]` | Formats of conversions, in priority order ([Formats](#formats)) |

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
  format: :webp,           # Output format (:jpg, :png, :webp, :avif, or :original)
  formats: [:avif, :webp], # Or several, in priority order (see Formats)
  collections: [:images]   # Only apply to these collections
```

A conversion with `format:` is stored with that format's extension:
`photo_name.webp` for a JPEG original. Without `format:`, conversions are
WebP, in every collection; `format: :original` keeps the original's format.
Outlook for Windows can't show WebP, so use `format: :original` for
conversions sent in emails.

### Formats

`formats:` makes each conversion in several formats, in priority order.
Set it on a conversion, a collection, or globally with
`config :phx_media_library, formats: [...]`; the most specific wins.
Quality can be set per format:

```elixir
media_collections do
  collection :photos, formats: [avif: [quality: 50], webp: [quality: 80]]
end

media_conversions do
  convert :thumb, width: 300, fit: :cover                # the collection's formats
  convert :og, width: 1200, height: 630, format: :jpg    # one format: formats: [:jpg]
end
```

The last format is the safe one: `url(media, :thumb)`, `og:image` and
emails get it, since AI tools and most link previews can't read AVIF.
The earlier formats are offered through `<picture>`. Responsive variants
come in the same formats, and a `formats:` list you set also makes the
original's AVIF and WebP copies ([WebP](#webp-conversion), [AVIF](#avif)),
unless the collection says `webp: false` or `avif: false`. The default is
`[:webp]`; `:original` is the uploaded file's format, and `avif: true` is
short for `[:avif, :webp]`. SVGs, PDFs and other files libvips can't
convert keep their own format.

Conversions made before you change `formats:` keep their files until
`mix phx_media_library.doctor --rebuild --only conversions`.

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

If you change conversion definitions, rebuild them for existing media:

```bash
mix phx_media_library.doctor --rebuild --only conversions --conversion thumb
mix phx_media_library.doctor --rebuild --only conversions --collection images
mix phx_media_library.doctor --rebuild --only conversions --dry-run
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

Conversions are WebP in every collection (`photo_thumb.webp`), unless the
conversion sets its own `format:`.

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
| `:max_dimension` | `nil` | Fit the WebP inside a square of this many pixels (aspect kept, never upscaled). `nil` keeps the source size |

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
- `max_dimension: 1200` caps the served WebP at 1200px on its longest edge and
  records the result in `custom_properties["webp_width"]`/`["webp_height"]`.
  Combine with `keep_original: false` when uploads are far larger than any
  view needs, so storage grows with what you display rather than what was
  uploaded. Responsive variants wider than the cap are skipped.

Regenerate WebP from each media's original after changing `quality` (or after
enabling WebP on existing media):

```bash
mix phx_media_library.doctor --rebuild --only webp
mix phx_media_library.doctor --rebuild --only webp --collection photos --dry-run
```

> Regeneration reads the original, which is why `keep_original: true` is the
> default. Media stored with `keep_original: false` have no source and are
> skipped with a warning.

Switching an existing collection to `keep_original: false` (or adding a
`max_dimension`) is a three-step migration, in this order:

```bash
mix phx_media_library.doctor --rebuild --only webp,responsive --model products
mix phx_media_library.doctor --drop-originals --model products   # last: the rebuild reads the original
mix phx_media_library.clean --files-only                          # local disks; then --force to delete stale variants
```

## AVIF

AVIF files are smaller than WebP at the same quality. Turn it on per
collection, or globally with `config :phx_media_library, avif: true`:

```elixir
media_collections do
  collection :photos, webp: true, avif: true, responsive: true
  collection :hero,   avif: [quality: 60]
end
```

- The AVIF is stored beside the original, at the served file's size (inside
  WebP's `max_dimension`, when set). Without `quality:`, libvips uses its
  default.
- `avif: true` is short for `formats: [:avif, :webp]`: conversions and
  responsive variants come in both. Plain URLs are the WebP, so a plain
  URL is never AVIF.
- `<.picture>` and `<.responsive_img>` offer the AVIF `srcset` first and
  the WebP one on the `<img>`, so browsers without AVIF still get an image.
  `<.responsive_img>` wraps it in `<picture style="display: contents">`,
  so your layout sees only the `<img>`:

```html
<picture>
  <source type="image/avif" srcset="…_160w.avif 160w, …_320w.avif 320w, ….avif 1200w">
  <img src="….webp" srcset="…_160w.webp 160w, …_320w.webp 320w, ….webp 1200w" width="1200" height="800" alt="…">
</picture>
```

AVIF needs a libvips built with AVIF support (through libheif); without it,
uploads go on without AVIF and a warning is logged once.
`mix phx_media_library.doctor` reports media missing their AVIF;
`--regenerate` creates it.

## Placeholders

Every image gets a placeholder that shows its shape and colors while it
loads, with no JavaScript. It is made in the background after the upload
(by the async processor), and the components set it as the image's inline
background: `<.media_img>`, `<.responsive_img>`, `<.picture>` and the
gallery.

```elixir
media_collections do
  collection :products, placeholder: :blur          # default: a 32px WebP, about 260 bytes
  collection :heroes,   placeholder: [size: 64]     # smoother, about 600 bytes
  collection :avatars,  placeholder: :color   # the average color
  collection :icons,    placeholder: false
end

# Or for every collection without its own:
config :phx_media_library, placeholder: :color
```

Images with transparency (a product cut-out on a transparent background)
get no placeholder, since it would show through once they load.

For your own `<img>` tags, `PhxMediaLibrary.ViewHelpers.placeholder_style/2`
returns the CSS. Media uploaded before 0.9 has none, or 0.8's heavier JPEG
one, until the doctor makes it (`mix phx_media_library.doctor
--regenerate`). After changing the size, remake them all with
`mix phx_media_library.doctor --rebuild --only placeholders`.

> The doctor reports missing and outdated placeholders, not ones made with
> other settings: after changing `placeholder:` (type or size), run the
> rebuild above yourself.

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
format. The original's variants come in each listed format
([Formats](#formats)) it has a full-size file in: its AVIF, its WebP, or
itself; a conversion's, in every format it was made in. Each format gets
its own `srcset`. With `webp: [max_dimension: n]` the largest descriptor is the capped
WebP at its real size, and widths above it are not generated.

Conversions get variants too. One with the original's shape (a width-only
`:preview`, say) gets none of its own when the original's variants are in
the same format (WebP, in a `webp: true` collection): its `srcset` lists
the original's variants narrower than it, then the conversion itself,
since those files would be the same. Crops (`:thumb`, `:banner`) get their
own, and so does a conversion whose formats differ from the original's
variants, so a `srcset` never mixes formats.

For a fixed-size slot (a cart thumbnail, a search result) ask for a single
variant instead of a `srcset`. `width:` returns the smallest variant at least
that wide, the widest one when none is, or the regular URL for media without
variants:

```elixir
PhxMediaLibrary.get_first_media_url(product, :photos, width: 320)
PhxMediaLibrary.Media.url(media, nil, width: 320)
# => "…/responsive/photo_320w.webp"
```

You can also request variants ad hoc for a single upload:

```elixir
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.with_responsive_images()
|> PhxMediaLibrary.to_collection(:images)

PhxMediaLibrary.srcset(media)
# => "…/responsive/image_320w.webp 320w, …/responsive/image_640w.webp 640w, …"
```

Configure the default widths globally:

```elixir
config :phx_media_library,
  responsive_images: [
    enabled: true,          # the default
    widths: [320, 640, 960, 1280, 1920]
  ]
```

Originals and conversions get variants only in collections that set
`responsive:` (an upload can ask for the original's with
`with_responsive_images/1`). `enabled: false` turns them off everywhere.

Rebuild responsive variants for existing media after changing widths:

```bash
mix phx_media_library.doctor --rebuild --only responsive
mix phx_media_library.doctor --rebuild --only responsive --collection photos
```

See the [LiveView guide](liveview.md) for rendering responsive images with the
`<.responsive_img>` and `<.picture>` components.