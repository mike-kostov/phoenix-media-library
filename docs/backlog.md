# Backlog

Planned work that has no spec yet. When work starts, it gets a spec in
`docs/specs/` and a plan in `docs/plans/`, and leaves this file.

## 0.9.0

Done: everything agreed for 0.9.0 is in `docs/specs/01-release-0.9.0.md`
and `docs/plans/01-release-0.9.0.md`, tagged 2026-10-04. Mike publishes it
to Hex before 0.10.0, so 0.8.4 users see its deprecation notices first.

## 0.10.0 (specced in `docs/specs/02-release-0.10.0.md`, draft)

Carried into spec 02: F1 formats and C3 indexes (below), plus C1
removals, C2 responsive rule, P1 database spike, F2 bulk ingestion, F3
binary and stream input, F4 copy and move, F5 dimension limits, F6
processing status, F7 PDF thumbnails, F8 Google Cloud Storage (moved from
"After 0.9.0"). The items below stay here
until the spec is approved.

Release plan (Mike, 2026-10-04, revised the same day): 0.9.0 is published
to Hex before 0.10.0, so its deprecation notices reach users; 0.10.0 then
removes what 0.9.0 deprecated. The library is 0.x with few users, so
breaking changes are acceptable with a CHANGELOG entry and upgrade notes.

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
- LiveDashboard page with media stats. Mike (2026-10-05) wants to think
  this through as an admin page for the doctor: the report, with repair
  buttons, on top of `PhxMediaLibrary.Doctor` (spec 02, F9).
- Migration guide for changing `mediable_type` values (ADR-007).

Done since `PRIORITIES.md` was written: internationalized filenames
(transliteration, ADR-015) and pre-signed download URLs (`signed_url/3`).
