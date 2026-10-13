# Backlog

Planned work that has no spec yet. When work starts, it gets a spec in
`docs/specs/` and a plan in `docs/plans/`, and leaves this file.

## 0.9.0

Done: everything agreed for 0.9.0 is in `docs/specs/01-release-0.9.0.md`
and `docs/plans/01-release-0.9.0.md`, tagged 2026-10-04. Mike publishes it
to Hex before 0.10.0, so 0.8.4 users see its deprecation notices first.

## 0.10.0

Done: everything agreed for 0.10.0 is in `docs/specs/02-release-0.10.0.md`
and `docs/plans/02-release-0.10.0.md`, published to Hex 2026-10-13. Checked
before release in three apps: two on Postgres, one on SQLite.

## After 0.10.0

Trials on real services:
- Try the S3 adapter on a real provider: Cloudflare R2's free tier with
  a real project's images (presigned PUT and its signed Content-Type, uploads
  without an ACL, public URLs through `base_url`). Ticks the open
  assumptions in `docs/ideas/s3-providers.md` (Mike, 2026-10-04).
- Try the `:gcs` preset on a real bucket: put, multipart, ranged GET,
  signed GET and PUT, and whether POST forms with `X-Amz-*` fields work
  (`docs/ideas/gcs.md` lists what Google's docs don't confirm). Spec 02's
  F8 shipped without it.

Testing:
- Run the FFmpeg tests before the next release: 0.10.0 was checked
  without FFmpeg installed, so they were skipped (the video code had not
  changed since 0.9.0). `brew install ffmpeg`, or a container with it.
- Postgres in a reused test container (deferred in ADR-026). For now a
  manual one, `phx-media-library-db` (README, Contributing); next, start
  it from `test_helper.exs` like Ministack.
- Keep the `spike/testcontainers` branch for local experiments.

Found in 0.10.0's app upgrades (2026-10-09 to 2026-10-12):
- The doctor's report lists five media per issue and "... and N more".
  A flag to list them all (or write them to a file): finding which 2,000
  images had old placeholders took a database query.
- Placeholders under `object-fit: contain`: the guide says to turn them
  off, since the placeholder covers the whole box and shows around the
  image. An option to size it like the image instead (`background-size:
  contain`, centred) would keep it for those images.
- The drop zone's `.MediaDropZone` hook is rendered but no element sets
  `phx-hook` to it, so its drag classes (`phx-media-dragging`,
  `phx-media-dropped`) are never added. Attach it or remove it (found
  with spec 02, B13).
- `ResponsiveImages.WidthCalculator` is public but the library no longer
  calls it; only a doctest does. Removing it breaks apps that use it:
  decide, and deprecate first if it goes.
- The 0.10.0 package's CHANGELOG dates the release 2026-10-12; Hex has
  2026-10-13. The repository's CHANGELOG is corrected; the next package
  carries it.

Database (`docs/ideas/db-performance.md`):
- Retest fillfactor on the media table with the 0.10 write pattern: the
  100k rerun saw HOT updates at 20/s fall from 80% to 36–58%, as the
  job's final update rewrites about 2 kB of a row the insert filled.
- Measure how close real rows (photos with EXIF, long names) come to the
  TOAST threshold: the heavy test row is 1,992 bytes against 2,032.

0.11:
- The app's own images through the library, by key, with a repeatable
  sync (`docs/ideas/system-assets.md`, Mike 2026-10-09).


## Parking lot

Carried over from `PRIORITIES.md`, with what has changed since.

- Library rename: `docs/ideas/library-name.md`.
- A separate table for responsive variants (Mike, 2026-10-08). The spike
  found it would add a join or query to every page that shows media; the
  compact format above is the cheaper win. Revisit if per-media variant
  sizes become a need.
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
