# Backlog

Planned work that has no spec yet. When work starts, it gets a spec in
`docs/specs/` and a plan in `docs/plans/`, and leaves this file.

## 0.9.0 (agreed, not yet specced)

Bugs and issues found while working on 0.9.0 go into 0.9.0. Before
publishing, the whole backlog is reviewed again.

### Security
- Direct-to-S3 uploads trust the browser. `presigned_upload_url/3` drops
  the size and type limits (ExAws ignores `content_length_range`), and
  `complete_external_upload/4` stores the client's filename, type and size
  without the collection's `accepts`/`max_size` or checking that the object
  exists. It also reads the media UUID from the wrong path segment under
  the Tenant path generator.
- SVG uploads served from the uploads folder run their scripts when opened
  directly. Serve SVG as attachment or with a restrictive CSP, and document
  the `Plug.Static` setup.
- `ImageProcessor.Image` turns a file extension into an atom
  (`String.to_atom`), so unusual extensions slowly fill the atom table.

### Bugs
- URL helpers don't percent-encode paths, so media stored before ADR-015
  with spaces or `#` in the name has broken URLs until renamed.
- `LiveUpload.consume_media/5` returns an error for the whole batch when one
  entry fails, so the media already saved isn't reported back.
- `Plug.MediaDownload` reads the whole file into memory; use `send_file`.
- Dead `Process.delete` in `MediaAdder.stream_and_checksum/3`.

### Features
- Original filenames on document downloads. Since ADR-015 a downloaded
  invoice is named after its stored file (`orders_15_invoices_<uuid>.pdf`);
  the download should carry the uploaded name, signed into the download
  URL so it can't be tampered with.
- `doctor --id` to check and repair one media item.
- AVIF next to WebP, served through `<picture>` with WebP as fallback.
- `<.media_figure>` component with a caption from
  `custom_properties["caption"]`.
- Placeholders: see `docs/ideas/placeholders.md` (needs a decision).

### Project
- Make `mix precommit` pass: 16 `credo --strict` findings and the
  unformatted `lib/phx_media_library/path_generator/tenant.ex` (ADR-022).
- Docs and examples pass over the README and guides for everything new in
  0.9.0.
- Release 0.9.0.

## After 0.9.0
- Copy or move media between records.
- Add media from a binary, base64 or a stream (`{:stream, enumerable}`).
- PDF thumbnails.
- Google Cloud Storage adapter.
- Processing status for conversions (pending, done, failed).
- Minimum and maximum image dimensions per collection.
- Unify the responsive rules for originals and conversions (ADR-017).
- Remove the deprecated repair tasks in 0.10.0 (ADR-016).

## Parking lot

Carried over from `PRIORITIES.md`, with what has changed since.

- Library rename: `docs/ideas/library-name.md`.
- Test factory helpers (ExMachina) for media fixtures in app tests.
- `Ecto.Multi` integration for transactional add and delete.
- Custom filename strategies (a function). The built-in strategies of
  ADR-015 cover most needs.
- Quota system: per-model or per-user storage limits.
- Event or webhook system beyond Telemetry.
- Zip download of a collection.
- Duplicate detection from checksums.
- Auto-rotation from EXIF orientation.
- Drag-and-drop reordering in the gallery (`.MediaSortable`); the
  `reorder/3` API exists.
- `ImageProcessor.Mogrify` adapter.
- `<.media_upload>` that detects S3 and uploads directly, and an
  `:external` option for `allow_media_upload/3`.
- On-the-fly image transformation URLs (like Imgix).
- LiveDashboard page with media stats.
- Migration guide for changing `mediable_type` values (ADR-007).

Done since `PRIORITIES.md` was written: internationalized filenames
(transliteration, ADR-015) and pre-signed download URLs (`signed_url/3`).
