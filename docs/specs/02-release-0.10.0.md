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
   (Mike, 2026-10-09: SQLite is supported in 0.10.0, F10, after an app
   that runs on it upgraded.)
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
  `webp:` and `avif:`, except that an explicit `formats:` list (on the
  collection or global, not the default `[:webp]`) turns on the copy in
  each format it lists, so the original's variants come in them too;
  `webp: false` or `avif: false` at the same or a more specific level
  still wins. (Mike, 2026-10-08, at the Formats checkpoint.) `avif: true` becomes shorthand for
  `formats: [:avif, :webp]`; a conversion's `format: x` for
  `formats: [x]`.
- Delete, clean, rename, the doctor and shared variants (F8 of spec 01)
  handle several formats per size.

**F2. Bulk ingestion.** (Mike, 2026-10-05) A route for importing many
media at once that doesn't write each row six to eight times. From P1
(recommendation 4): rows are written once with `insert_all`, in batches
of 1,000 (Postgres caps one call at 3,449 media rows), and conversions,
variants and placeholders run later in the background with one update
per row; indexes are not dropped and rebuilt for imports smaller than the
table. Measured: 4,000 to 6,000 rows/s on one connection, 3 to 5 kB of
WAL per row against 20 to 26 kB per upload.

Decided (Mike, 2026-10-08):
- `PhxMediaLibrary.import_media(entries, opts)` takes a list or stream of
  `%{model:, collection:, source:}` entries (with optional
  `custom_properties:` and `filename:`), across any models and
  collections. Each file is checked and stored like an upload; rows go in
  with `insert_all` in batches; it returns the count and each failed
  entry with its error.
- Everything derived (WebP, AVIF, the original's variants, conversions,
  placeholders) is made in the background, one job and one update per
  row.

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
step. P1 measured the cost: the finish rides on the job's one update, the
start is one extra write.

Decided (Mike, 2026-10-08):
- Always on: four columns, `processing_started_at`,
  `processing_finished_at`, `processing_failed_at` and `processing_error`
  (text), in every media table. Upgrading apps run a migration
  (`mix phx_media_library.gen.migration --processing-status`), a breaking
  step listed in the changelog; new installs get the columns.
- The migration marks existing rows done without rewriting them (a
  default of the migration's time, then dropped), so nothing from before
  0.10 reads as queued.
- `Media.processing_status/1` returns `:queued`, `:processing`, `:done`
  or `:failed`. Media with no background work is done when inserted.

**F7. PDF thumbnails.** (backlog; Mike 2026-10-05) A PDF's first page
becomes its image: conversions (`:thumb`, `:preview`) and the placeholder
are made from it, so PDFs show in galleries and components like images,
while the PDF itself is served for download. The conversions get
responsive variants like any image's; the PDF itself gets none, nor does
any other document, since a `srcset` ends with a full-size image (Mike,
2026-10-08).
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

**F10. SQLite.** (Mike, 2026-10-09, during the upgrade of an app that
runs on SQLite; P1's assessment in `docs/ideas/db-performance.md`.) The
library works on SQLite (`ecto_sqlite3`) as on Postgres, and says so.
- The whole suite runs on both: `mix test` on Postgres, and on SQLite
  with an environment switch; `mix precommit` runs both.
- Generated migrations (install, `--processing-status`, `--indexes`) work
  on each: SQLite has no `CONCURRENTLY`, no `ALTER COLUMN` and no
  `timezone()`.
- What is Postgres-only gets a SQLite answer: the scheduler's advisory
  lock (one node on SQLite), `import_media`'s batch size (SQLite's
  parameter limit), Oban's Lite engine in the docs.
- A guide section: WAL mode, `busy_timeout`, Oban on SQLite.

**F11. Onboarding without surprises.** (Mike, 2026-10-09, after an
app's upgrade showed JPEGs and no placeholders.)
- Without `:image`, the first image upload logs that images are stored
  as uploaded, and the doctor's report says so.
- With `blurhash: true`, the doctor finds images without a hash
  (`missing_blurhash`) and `--regenerate` makes them; the background job
  makes a missing one.
- The LiveView guide shows the `phoenix-colocated/phx_media_library`
  import, explains that plain URLs are WebP and AVIF and placeholders
  come from the components' markup, and lists the public functions for
  writing that markup yourself.

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
2026-10-05; confirmed by P1, `docs/ideas/db-performance.md`) In the
installer template: drop (mediable_type, mediable_id) (redundant with the
three-column index), (collection_name) (only `stats --collection` uses
it) and the checksum index (no library query reads it); make
(deleted_at) partial. P1 found no read slower without them; WAL per
upload drops by a third and index space halves. Existing apps get an optional migration and an upgrade note. P1 may
add to this.

**C4. Fewer writes per upload.** (Mike, 2026-10-08; recommendation 2 of
`docs/ideas/db-performance.md`.) Today the heaviest upload writes its
media row seven times (an insert and six updates); under 100 uploads/s at
1M rows that slows the app's reads (preload p95 41 ms against 11 ms when
each row is written once).
- On upload, the WebP, AVIF and responsive results go into the insert;
  the background work ends with one update for the conversions, their
  variants and placeholders.
- Repairs (the doctor) keep writing per step: `Pipeline` steps can return
  their changes instead of writing them (ADR-014 holds).
- No migration; F6's `processing_finished_at` rides on the final update.

**C5. Time-ordered ids.** (Mike, 2026-10-08; P1 recommendation 5) New
media get monotonic UUIDv7 values for `id` and `uuid` (a counter within
each millisecond), generated by the library without a new dependency.
Measured: bulk load 26% faster, primary key and uuid indexes 21% and 23%
smaller. Existing v4 rows stay as they are; the columns don't change.

**C6. Compact responsive data.** (Mike, 2026-10-08; P1 recommendation 6)
`responsive_images` stores each variant's width (and format) instead of
its full path; paths are derived the way conversion paths are. Measured:
preload p95 -18%, TOAST -25%, the heaviest row's value -74%. Done together
with F1, which changes the same data; old rows keep reading, and the
doctor rewrites them.

**C7. `move_to/2` is `set_position/2`.** (Mike, 2026-10-08) The name
read like `move_media/4` (F4). Renamed, with no deprecated alias
(ADR-027).

### Bugs

**B1. The library compiles without its optional dependencies.** (Found
2026-10-07, in Task 7's release check.) In an app without Phoenix
LiveView, compiling the library failed: `ViewHelpers`, `Components`,
`MediaLive` and `LiveUpload` used LiveView unguarded, and `MediaAdder`
matched `%Plug.Upload{}`, which needs Plug. Without `:image` it warned
(an unused function in `Blurhash`, a never-matching clause in
`MediaAdder`). Present in 0.9.0 and before. Fixed in 0.10.0, with no 0.9.1 (Mike,
2026-10-08).
- An app with none of the optional dependencies compiles the library
  with no errors and no warnings.

**B2. Conversion records aren't silently lost.** (Found 2026-10-08 by the
database spike.) `Conversions.update_generated_conversions/2` ignores the
result of its database update and always returns `:ok`, so a failed write
leaves files on storage that the record doesn't know about, and the
caller reports success.
- A failed update is returned (or at least logged) and the job can retry.

**B3. Global `webp: true` works.** (Found 2026-10-08 in Task 11's
follow-up.) `config :phx_media_library, webp: true`, as the `Config` docs
show it, raised `FunctionClauseError` wherever WebP settings were read, so
every image upload failed; only the keyword form worked. Present in 0.9.0
and before.
- `webp: true` and `webp: false` work globally, as `avif:` already did.

**B4. No failing conversion jobs for files that aren't images.** (Found
2026-10-08 in Task 15.) In a collection with conversions, every upload
queued a conversions job, whatever the file: for a PDF or a text file the
job failed ("Failed to find load"), and Oban retried it. Present in 0.9.0
and before.
- Files that aren't images queue no conversions, and a job for one
  succeeds without doing anything.

**B5. No failing conversion jobs without an image library.** (Found
2026-10-08 in Task 21's audit.) In an app without `:image`, every image
upload to a collection with conversions queued a job that always failed
(`:no_image_processor`), and Oban retried it. Present in 0.9.0 and before.
- Without an image processor, uploads queue no conversions and are done
  at once.

**B6. The LiveView requirement matches the components.** (Found
2026-10-08 in Task 21's audit.) The components use
`Phoenix.LiveView.ColocatedHook`, added in LiveView 1.1.0, while
`mix.exs` accepted `phoenix_live_view ~> 1.0`: an app on 1.0 resolved the
library and then failed to compile its components. Present in 0.9.0.
- The library requires `phoenix_live_view ~> 1.1`.

**B7. `MediaLive` survives a refused file.** (Found 2026-10-09 while
covering `MediaLive` with tests.) Submitting the upload form while a file
LiveView had refused (too large, wrong type) was listed crashed the page:
`consume_uploaded_entries/3` raises while any entry is unfinished.
Present in 0.9.0 and before.
- Refused files are dropped on submit and named in the flash; finished
  ones are saved; the page stays up.

**B8. `MediaLive` reports what it saved.** (Found with B7.) When one file
of an upload failed, the parent LiveView heard nothing, not even about
the files that were saved.
- The parent gets `{:uploaded, collection, saved}` whenever any file was
  saved, alongside the error.

**B9. `<.blurhash>` keeps its shape.** (Found 2026-10-09 while covering
the components with tests.) Its canvas had `style="… aspect-ratio:
{@width} / {@height};"` as a plain string, so the braces reached the
browser and the aspect ratio was dropped as invalid CSS. Present in 0.9.0
and before.
- The canvas's `aspect-ratio` is its width and height.

**B10. Date-based paths keep their day.** (Found 2026-10-09 while
covering the path generators with tests.) `PathGenerator.DateBased` built
every path from `Date.utc_today()`, so from the day after an upload its
URLs, deletes and conversions pointed at a folder that didn't hold the
file. Present in 0.9.0 and before.
- Paths use the day of the media's `inserted_at`, which an upload, a move
  and an import set to the time the file was stored.

**B11. BlurHash colours round like the reference encoder.** (Found
2026-10-09 while covering `Blurhash` with tests.) The average colour was
rounded as `round(x * 255 + 0.5)`, half a step too high, so channels came
out one too bright and hashes differed from other BlurHash encoders.
Present in 0.9.0 and before.
- The DC colour decodes to the image's average colour.

**B12. No metadata the doctor can't repair.** (Found 2026-10-09 in an
app's upgrade.) Without an image library, the doctor reported every image
as missing metadata, and `--reextract` reported each repair done while the
dimensions stayed missing, run after run. Present in 0.9.0.
- Without an image processor, images aren't reported as missing their
  dimensions.

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
warnings anywhere (as 0.9.0's P5). The guides include the autovacuum
setting for busy media tables (P1 recommendation 7: the default waits for
20% of the table to be dead rows).

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
- F6: a media item's status reads queued, processing, done or failed
  through its background job, which adds one write (its start). Always on
  (Mike, 2026-10-08), so "off" no longer applies.
- F7: with libvips PDF support or `pdftoppm` available, a PDF gets a
  `:thumb` image and a placeholder from its first page; without either,
  the upload succeeds and logs once.
- F8: put, get, delete, public and signed URLs and a direct upload work
  against GCS (an emulator in tests, if one exists without an account).
  Not met in 0.10.0: no emulator accepts S3 writes and no bucket was
  available, so the `:gcs` preset ships with unit tests and says so; a
  real bucket trial is in the backlog (Mike, 2026-10-08).
- F9: `bin/media_doctor` from the generator runs the doctor in a release
  with the mix task's flags.
- F9: with `:doctor_schedule` enabled, a run happens at `at:` through Oban
  or the internal runner, on one node only, and only the listed repairs
  run; disabled by default.
- F9: `PhxMediaLibrary.Doctor.check/1` and `repair/2` work without Mix
  (tested with Mix's shell unavailable), return the same results as the
  mix task, emit a telemetry event per run, and process media in batches.
- F10: the suite passes on Postgres and on SQLite, and an app on SQLite
  upgrades from 0.9 with the generated migrations.
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
