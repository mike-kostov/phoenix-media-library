# Backlog

Planned work that has no spec yet. When work starts, it gets a spec in
`docs/specs/` and a plan in `docs/plans/`, and leaves this file.

## 0.9.0

Done: everything agreed for 0.9.0 is in `docs/specs/01-release-0.9.0.md`
and `docs/plans/01-release-0.9.0.md`, tagged 2026-10-04 (not published to
Hex).

## 0.10.0 (agreed, not yet specced)

Release plan (Mike, 2026-10-04): 0.9.0 is tagged and pushed but not
published to Hex; 0.10.0 follows directly and is the next published
release, so its CHANGELOG and upgrade notes cover 0.8.x to 0.10.0.

- An ordered `formats:` list (Mike, 2026-10-04; ADR-024 amendment).
  Agreed shape:
  - Per collection, and per conversion (a conversion's list wins):
    `collection :products, formats: [:avif, :webp]`,
    `convert :email, width: 600, formats: [:original]`.
  - Quality per format, as a keyword list that keeps the order:
    `formats: [avif: [quality: 50], webp: [quality: 80]]`; plain atoms
    mix in.
  - Priority order: the library makes each conversion and responsive
    variant in every listed format, from the original. The last format is
    the safe one: `url/2`, `og:image`, emails and the `<img>` use it; the
    earlier ones become typed `<picture>` sources in order.
  - `:original` means the uploaded file's format (a PNG stays PNG).
  - Covers conversions and variants only; the original's own copies stay
    with `webp:` (served copy, `keep_original`, `max_dimension`) and
    `avif:`.
  - `avif: true` becomes shorthand for `formats: [:avif, :webp]`.
  - Default `[:webp]`, as 0.9.0's safe defaults (F7a).
  - Touches paths and `generated_conversions` (several extensions per
    conversion), the `responsive_images` data (variants per format),
    delete, clean, rename, the doctor, shared variants (F8) and the
    components. Needs its own spec.
- Media table indexes, per `docs/ideas/media-indexes.md` (Mike, 2026-10-04):
  drop the redundant (mediable_type, mediable_id) index, make
  (deleted_at) a partial index, consider dropping (collection_name); in
  the installer template, plus an optional migration and an upgrade note
  for existing apps. Decide first whether the unused checksum index stays
  (apps may use it to find duplicates).

## After 0.9.0

Found during 0.9.0 (Mike, 2026-10-04):
- Try the S3 adapter on a real provider: Cloudflare R2's free tier with
  a real project's images (presigned PUT and its signed Content-Type, uploads
  without an ACL, public URLs through `base_url`). Ticks the open
  assumptions in `docs/ideas/s3-providers.md`.
- Postgres in a reused test container (deferred in ADR-026: the spike's
  container was killed at the end of each run).
- Keep the `spike/testcontainers` branch for local experiments.

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
