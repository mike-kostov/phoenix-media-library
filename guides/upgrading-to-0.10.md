# Upgrading to 0.10

0.10 needs one migration, a rename, and a look at four removals. The rest
of this page lists changes you might notice and the new features.

```elixir
{:phx_media_library, "~> 0.10"}
```

0.x releases rename and remove things without a deprecation period
(ADR-027); every such change is below.

## Required steps

### 1. Run the migration

The media table gets four columns for `Media.processing_status/1`:

```bash
mix phx_media_library.gen.migration --processing-status
mix ecto.migrate
```

Without them every media query fails, since the schema selects the new
columns. Existing rows read as done. Postgres adds the columns without
rewriting the table, so the migration is quick even on a large table; on
SQLite it marks the rows with an `UPDATE`.
Use `--table NAME` if your media table has another name.

### 2. Rename `move_to/2`

`PhxMediaLibrary.move_to(media, position)` is now
`PhxMediaLibrary.set_position(media, position)`, with the same arguments.
`move_media/4` is new and moves media to another record or collection.

### 3. Replace what 0.9 deprecated

| Removed | Use |
|---|---|
| `PhxMediaLibrary.presigned_upload_url/3` | `presigned_upload/3` ([storage guide](storage.md#direct-uploads-to-s3)) |
| the `presigned_upload_url/3` storage callback | `presigned_upload/3` in custom adapters |
| `mix phx_media_library.regenerate` | `mix phx_media_library.doctor --rebuild --only conversions` |
| `mix phx_media_library.regenerate_webp` | `mix phx_media_library.doctor --rebuild --only webp` |
| `mix phx_media_library.regenerate_responsive` | `mix phx_media_library.doctor --rebuild --only responsive` |
| `mix phx_media_library.drop_originals` | `mix phx_media_library.doctor --drop-originals` |

### 4. Conversions follow their collection's `responsive:`

Conversions get responsive variants only in collections that set
`responsive:`, like originals (ADR-017). In 0.9 they got them whenever
the global `responsive_images` switch was on, which is its default. If
your conversions had `srcset`s, set `responsive: true` on their
collections.

## After upgrading

Run the doctor and read its report:

```bash
mix phx_media_library.doctor
```

Two rebuilds are worth running, both optional:

```bash
# Rewrites responsive data in 0.10's compact shape (0.9 rows keep working).
mix phx_media_library.doctor --rebuild --only responsive

# Collections with avif: true: makes the AVIF of existing conversions.
mix phx_media_library.doctor --rebuild --only conversions
```

On a large table, consider the leaner indexes of new installs:

```bash
mix phx_media_library.gen.migration --indexes
```

It drops the (mediable_type, mediable_id), (collection_name) and
(checksum) indexes, which no library query needs, and makes (deleted_at)
partial, `CONCURRENTLY`, so the table keeps taking writes. Keep the
checksum index if your app looks media up by checksum.

## Changes you may notice

### Data

- **`responsive_images`** stores each source's widths, full size and
  formats instead of a path per variant. Code that read
  `responsive_images["original"]["variants"]` should call
  `PhxMediaLibrary.ResponsiveImages.variants/2` or
  `Media.responsive_variants/2`, which read both shapes.
- **`generated_conversions`** records a list of extensions for a
  conversion made in several formats (`"thumb" => ["avif", "webp"]`). One
  format is recorded as before. `PathGenerator.conversion_paths/2` lists
  the files.
- **New ids** are UUIDv7, time-ordered. The columns don't change and
  existing ids keep working.

### AVIF and formats

- `avif: true` is now short for `formats: [:avif, :webp]`: conversions
  and responsive variants come in both formats, where 0.9 made AVIF
  variants only and WebP conversions. Plain URLs stay WebP.
- The image components offer each format as a typed `<source>` and put
  the last on the `<img>` with its own `srcset`. They no longer add a
  `<source>` for the full-size WebP the `<img>` already serves.
- A `formats:` list you set on a collection or globally also makes the
  original's AVIF and WebP copies in the formats it lists.

### Background work

- An upload writes its row three times in all: the insert (now carrying
  the WebP, AVIF and the original's variants), the job's start and its
  end. 0.9 wrote the heaviest upload seven times.
- The job also makes the original's WebP, AVIF and variants if the row
  lacks them.
- Files that aren't images get no conversions job. In 0.9 a PDF or text
  file in a collection with conversions queued a job that always failed.
- PDFs get thumbnails when the server has poppler's `pdftoppm` (or a
  libvips that reads PDFs): their conversions and placeholder are made
  from the first page. If your servers have `pdftoppm`, PDFs in
  collections with conversions start getting them.
- `Conversions.process/2` returns `{:error, {:record_update_failed, reason}}`
  when it can't record what it made, so jobs retry.

### Fixes that change behaviour

- `config :phx_media_library, webp: true` works. In 0.9 it raised on every
  image upload; only the keyword form worked.
- The library compiles without Phoenix LiveView, Plug or `:image`.

## New in 0.10

| Feature | Where |
|---|---|
| `formats:`, conversions and variants in several formats | [Collections & conversions](collections-and-conversions.md#formats) |
| `add/2` from a binary, base64 or a stream | [Getting started](getting-started.md#add-media) |
| `import_media/2` for bulk imports | [Advanced](advanced.md#importing-many-media) |
| `copy_media/4` and `move_media/4` | [Advanced](advanced.md#copying-and-moving-media) |
| `min_width:` and other dimension limits | [Collections & conversions](collections-and-conversions.md#collections) |
| `Media.processing_status/1` | [LiveView](liveview.md#processing-status) |
| PDF thumbnails | [Collections & conversions](collections-and-conversions.md#pdf-thumbnails) |
| Google Cloud Storage (`provider: :gcs`) | [Storage](storage.md#amazon-s3-and-s3-compatible-services) |
| The doctor in releases and on a schedule | [Advanced](advanced.md#the-doctor-on-a-schedule) |
| SQLite | [Advanced](advanced.md#sqlite) |
| Autovacuum for busy media tables | [Advanced](advanced.md#busy-media-tables) |
