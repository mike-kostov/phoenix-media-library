# Spec 02: Release 0.10.0

Status: approved (Mike, 2026-10-07). 0.10.0 keeps growing: new features
are added here as they are agreed; fixes after its release go into 0.10.x.
Plan: `docs/plans/02-release-0.10.0.md`.
Source: `docs/backlog.md` (0.10.0 section), `docs/ideas/db-performance.md`,
`docs/ideas/media-indexes.md`, ADR-017, ADR-024 (amended).

## Objective

0.10.0 makes image formats configurable per app and per conversion, makes
sure the library doesn't slow down the apps it is in, adds ways to bring
media in (content, streams, bulk) and to copy or move it, adds dimension
limits, an opt-in processing status, PDF thumbnails, Google Cloud
Storage and a doctor that runs in production, removes what 0.9.0 deprecated, and
settles the responsive rules. 0.9.0 is on Hex, so the
upgrade notes cover 0.9 to 0.10. It is a minor 0.x release: breaking
changes are allowed, each with a CHANGELOG entry and an upgrade note.

## Assumptions

1. Postgres stays the only supported database in 0.10.0; SQLite is
   assessed by the database spike, and built only if Mike agrees after.
2. The database work starts as a spike (P1); changes it leads to are
   specced here after Mike reviews the numbers.
3. Commands, project structure, code style, testing and boundaries are
   those of spec 01 and `AGENTS.md`.

## Features

**F1. An ordered `formats:` list.** (backlog 0.10.0; ADR-024 amendment)
- `formats:` per collection and per conversion (a conversion's list
  wins), and globally. Default `[:webp]`, as 0.9.0's safe default.
- Priority order. Each conversion and responsive variant is made in every
  listed format, from the original. The last format is the safe one: plain
  URLs (`url/2`, `og:image`, emails) and the `<img>` use it; the earlier
  ones become typed `<picture>` sources, in order.
- Quality per format, as a keyword list that keeps the order:
  `formats: [avif: [quality: 50], webp: [quality: 80]]`; plain atoms mix
  in.
- `:original` means the uploaded file's format (a PNG stays PNG).
- Covers conversions and variants; the original's own copies stay with
  `webp:` and `avif:`. `avif: true` becomes shorthand for
  `formats: [:avif, :webp]`; a conversion's `format: x` for
  `formats: [x]`.
- Delete, clean, rename, the doctor and shared variants (F8 of spec 01)
  handle several formats per size.

**F2. Bulk ingestion.** (Mike, 2026-10-05) A route for importing many
media at once that doesn't write each row six to eight times. Its design
waits for the database spike (P1); this spec gets its details then.

**F3. Media from a binary, base64 or a stream.** (backlog; Mike
2026-10-05) `add/2` accepts in-memory content and streams as sources, not
only paths, uploads and URLs. The content is checked like any upload
(type from the bytes, collection limits). Bulk ingestion (F2) builds on it.

**F4. Copy and move media.** (backlog; Mike 2026-10-05) Copy or move a
media item, with all its files (conversions, WebP, AVIF, variants), to
another record or collection. The target collection's rules apply (accepted
types, limits, file naming), and a move that breaks them is refused.

**F5. Minimum and maximum image dimensions.** (backlog; Mike 2026-10-05)
Per-collection limits on width and height, e.g. avatars at least 200x200,
checked with the other upload validations and returned as tagged errors.

**F6. Processing status, opt-in.** (backlog; Mike 2026-10-05) Apps can
show whether an upload's background work is queued, running, done or
failed. Proposed (Mike): three timestamps on the media row,
`processing_started_at`, `processing_finished_at` and
`processing_failed_at` (with the error), from which the status is
derived; two writes per job instead of a status column rewritten at each
step. Off unless the app adds the columns (an optional migration) or turns
it on in config. P1 measures the cost before the design is final.

**F7. PDF thumbnails.** (backlog; Mike 2026-10-05) A PDF's first page
becomes its image: conversions (`:thumb`, `:preview`), the placeholder and
responsive variants are made from it, so PDFs show in galleries and
components like images, while the PDF itself is served for download.
Rendering uses libvips when it can read PDFs (the precompiled libvips of
`:image` can't, checked 2026-10-05), else the `pdftoppm` command-line
tool (poppler) when installed, like video posters use FFmpeg; without
either, PDFs are stored as today and a warning is logged once.

**F8. Google Cloud Storage.** (backlog; Mike 2026-10-05) Media can be
stored on GCS, with public and signed URLs and direct uploads. Either a
`provider: :gcs` preset of the S3 adapter, through GCS's S3-compatible API
with HMAC keys, or a native adapter on its JSON API. Decided from Google's
documentation (as `docs/ideas/s3-providers.md` did for R2): the preset if
the compatible API covers what the library uses.

**F9. The doctor at runtime.** (Mike, 2026-10-05) Releases have no
`mix`, so today the doctor can't run in production. Its logic moves into
`PhxMediaLibrary.Doctor`, a regular module: `check/1` returns a report
(issue counts and the media they concern, orphaned records, the
soft-delete backlog) and `repair/2` runs the repairs it is given. The mix
task becomes a thin wrapper (flags, output, confirmation) over the same
functions, so there is one implementation.
- Works anywhere the app runs; no `Mix` calls outside the task.
- `mix phx_media_library.gen.release` generates a small module in the app
  and a `rel/overlays/bin/media_doctor` script, so a release runs
  `bin/media_doctor --regenerate --yes` with the mix task's flags, the way
  Phoenix's `mix phx.gen.release` provides `bin/migrate`. (Mike,
  2026-10-05: no hand-typed `eval` in production.)
- Each run emits a telemetry event with the counts, for monitoring and
  alerting.
- On a schedule, from library config alone (`:doctor_schedule`: enabled,
  runner `:oban | :internal | :auto`, a daily `at:` time, the repairs
  allowed); off by default, report only by default, `rename`, `fix` and
  `drop_originals` refused, one node at a time. Design and its
  safeguards: `docs/ideas/scheduled-doctor.md` (agreed 2026-10-05).
- Checks media in batches, so large tables (P1's 1M rows) don't load into
  memory at once.
- The other maintenance tasks (`clean`, `purge_deleted`, `stats`) get the
  same split where their logic isn't already a function.

### Changes

**C1. Removed: what 0.9.0 deprecated.**
- `PhxMediaLibrary.presigned_upload_url/3` and the `presigned_upload_url/3`
  storage callback.
- `mix phx_media_library.regenerate`, `regenerate_webp`,
  `regenerate_responsive` and `drop_originals` (use the doctor).

**C2. One responsive rule.** (ADR-017) Today originals get responsive
variants only when their collection sets `responsive:`, while conversions
get them whenever the global `responsive_images` switch is on, which is
the default. 0.10.0 makes conversions follow their collection too: no
`responsive:`, no variants. Apps that relied on the old rule set
`responsive: true` on the collection; the upgrade notes say so.

**C3. Media table indexes.** (`docs/ideas/media-indexes.md`, Mike
2026-10-05) In the installer template: drop the redundant
(mediable_type, mediable_id) index and the checksum index, make
(deleted_at) a partial index, and drop (collection_name) unless P1 shows a
use. Existing apps get an optional migration and an upgrade note. P1 may
add to this.

### Bugs

**B1. The library compiles without its optional dependencies.** (Found
2026-10-07, in Task 7's release check.) In an app without Phoenix
LiveView, compiling the library failed: `ViewHelpers`, `Components`,
`MediaLive` and `LiveUpload` used LiveView unguarded, and `MediaAdder`
matched `%Plug.Upload{}`, which needs Plug. Without `:image` it warned
(an unused function in `Blurhash`, a never-matching clause in
`MediaAdder`). Present in 0.9.0 and before.
- An app with none of the optional dependencies compiles the library
  with no errors and no warnings.

**B2. Conversion records aren't silently lost.** (Found 2026-10-08 by the
database spike.) `Conversions.update_generated_conversions/2` ignores the
result of its database update and always returns `:ok`, so a failed write
leaves files on storage that the record doesn't know about, and the
caller reports success.
- A failed update is returned (or at least logged) and the job can retry.

### Project

**P1. Database spike.** (`docs/ideas/db-performance.md`) Postgres, 100,000
then 1,000,000 media rows:
- writes, dead rows, index writes and WAL per image upload, and their
  effect on concurrent reads;
- latency of what apps do: a page of records with media preloaded,
  `get_media` per record, joins from app tables to media, while uploads
  run;
- the levers ranked by measured effect, and what SQLite support would
  take.
Result: an idea doc with numbers and recommendations, reviewed with Mike.

**P2. Upgrade notes and docs.** `guides/upgrading-to-0.10.md` lists each
change from 0.9 and how to adapt; README and guides match 0.10.0; no
warnings anywhere (as 0.9.0's P5).

## Success criteria

- F1: a collection with `formats: [:avif, :webp]` stores every conversion
  and variant in both formats, `<picture>` offers AVIF then WebP, and every
  plain URL is WebP; a conversion with `formats: [:original]` stays in the
  upload's format.
- C1: the removed functions and tasks are gone, and the upgrade notes say
  what replaces each.
- C2: in a collection without `responsive:`, conversions get no variants.
- C3: new installs get the new indexes; the optional migration runs on a
  0.9 database.
- F3: `add/2` with a binary, base64 or a stream stores the same media as
  the same file from a path.
- F4: a copied media item has its own files and record; a moved one keeps
  its record and its files follow; collection rules apply to both.
- F5: an image below the minimum or above the maximum is refused with a
  tagged error naming the limit.
- F6: with status on, a media item's status reads queued, processing,
  done or failed through its background job; with it off, no extra
  writes.
- F7: with libvips PDF support or `pdftoppm` available, a PDF gets a
  `:thumb` image and a placeholder from its first page; without either,
  the upload succeeds and logs once.
- F8: put, get, delete, public and signed URLs and a direct upload work
  against GCS (an emulator in tests, if one exists without an account).
- F9: `bin/media_doctor` from the generator runs the doctor in a release
  with the mix task's flags.
- F9: with `:doctor_schedule` enabled, a run happens at `at:` through Oban
  or the internal runner, on one node only, and only the listed repairs
  run; disabled by default.
- F9: `PhxMediaLibrary.Doctor.check/1` and `repair/2` work without Mix
  (tested with Mix's shell unavailable), return the same results as the
  mix task, emit a telemetry event per run, and process media in batches.
- P1 is reviewed with Mike before F2 and F6 are final.
- `mix precommit` green, `mix docs` without warnings.

## Open questions

1. F2's shape, after P1.
2. F6: timestamps per media job (proposed) or per conversion; switched on
   by the columns' presence or by config; after P1.
3. F8: S3 preset or native adapter, after reading Google's documentation;
   a native adapter would need a new optional dependency (e.g. Goth for
   auth), which needs Mike's agreement.
4. Whether P1's results change C3 or F1 (for example, fewer writes per
   upload).
5. SQLite: after P1.
