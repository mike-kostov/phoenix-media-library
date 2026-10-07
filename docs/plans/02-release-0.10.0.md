# Implementation Plan: Release 0.10.0

Spec: `docs/specs/02-release-0.10.0.md` (approved 2026-10-07)
Status: approved (Mike, 2026-10-07)
Decisions: ADR-016 (removals), ADR-017 (responsive rule), ADR-024
(amended: formats)

0.10.0 keeps growing: features agreed later are added to the spec and get
tasks here. Fixes after its release go into 0.10.x.

## Overview

Measure first, then the small changes that make later work simpler, then
the doctor (its new module is what the release command and the schedule
build on), then the formats list, then the new ways to bring media in and
move it, then PDFs and GCS, and the two features that wait for the
database numbers last. Docs and the release close it. Every task is one
vertical slice and one commit, verified by its own tests (failing on the
old code first) and `mix precommit`. A checkpoint with Mike closes each
phase.

## Architecture Decisions

- **Measure before changing the table.** The database spike (Task 1)
  comes first; its numbers decide the index changes (Task 4), processing
  status (Task 18) and bulk ingestion (Task 19).
- **One doctor, three front doors.** `PhxMediaLibrary.Doctor` holds the
  logic; the mix task, `bin/media_doctor` and the schedule only parse,
  print or trigger. No `Mix` calls in the module.
- **Formats as data.** A resolved, ordered list of `{format, opts}` per
  collection and conversion (`Model`, ADR-014); everything downstream
  (paths, variants, components, the doctor) reads that list. The last
  format is the safe one. Existing records (`true` or one extension in
  `generated_conversions`) keep resolving as today.
- **New capabilities as adapters.** PDF rendering follows the video
  poster pattern (a behaviour with libvips and command-line adapters,
  detected at runtime); GCS is a storage preset or adapter, decided from
  Google's documentation before any code.
- **Removals are a clean break.** 0.9.0 on Hex carried the deprecation
  notices; 0.10.0 removes them with an upgrade note each.

## Dependency Graph

```
Task 1 (DB spike) ─┬─> Task 4 (indexes)
                   ├─> Task 18 (processing status)
                   └─> Task 19 (bulk ingestion) <── Task 12 (binary/stream input)

Task 5 (Doctor module) ─┬─> Task 6 (other maintenance tasks)
                        ├─> Task 7 (release generator)
                        └─> Task 8 (schedule)

Task 9 (formats config) ─> Task 10 (conversions) ─> Task 11 (variants, components)

Task 16 (GCS research) ─> Task 17 (GCS)
```

## Task List

### Phase 0: Measure

#### Task 1: Database spike (P1)
**Description:** Postgres, 100,000 then 1,000,000 media rows across
several models: statements, dead rows, index writes and WAL per image
upload; latency of preloads, `get_media` and joins from app tables while
uploads run; the levers ranked by measured effect; what SQLite support
would take. Scripts under `tmp/`, results in `docs/ideas/db-performance.md`.
**Acceptance criteria:**
- [ ] Measured numbers at both scales, with the method to rerun them.
- [ ] A ranked list of recommendations, each with its measured effect.
- [ ] A SQLite assessment (what is Postgres-specific, rough effort).
**Verification:** review with Mike.
**Dependencies:** none
**Files:** `docs/ideas/db-performance.md`, `tmp/` scripts
**Scope:** M

### Checkpoint: Measure
- [ ] Mike reviews the spike; spec 02 is updated with what it changes
      (C3, F2, F6).

### Phase 1: Small changes

#### Task 2: Remove what 0.9.0 deprecated (C1)
**Description:** Remove `PhxMediaLibrary.presigned_upload_url/3`, the
`presigned_upload_url/3` storage callback (and its fallback in
`StorageWrapper`), and the `regenerate`, `regenerate_webp`,
`regenerate_responsive` and `drop_originals` tasks.
**Acceptance criteria:**
- [x] The functions, callback and tasks are gone; nothing references
      them; tests that covered them are removed or moved to their
      replacements.
- [x] CHANGELOG and upgrade notes name each replacement. (CHANGELOG now;
      the 0.10 upgrade guide in Task 20.)
**Verification:** `mix compile --warnings-as-errors`; `mix precommit`.
**Dependencies:** none
**Scope:** S

#### Task 3: One responsive rule (C2, ADR-017)
**Description:** Conversions get responsive variants only when their
collection sets `responsive:` (or the upload asks), like originals.
`Model.conversion_responsive?/2` follows `Model.responsive?/3`.
**Acceptance criteria:**
- [x] In a collection without `responsive:`, conversions get no variants,
      whatever the global switch says.
- [x] With `responsive: true`, conversions get them as before.
**Verification:** pipeline and responsive tests (tested without the
library's own config); `mix precommit`.
**Dependencies:** none
**Scope:** S

#### Task 4: Media table indexes (C3)
**Description:** In the installer template: drop (mediable_type,
mediable_id), the checksum index and, unless Task 1 shows a use,
(collection_name); make (deleted_at) partial. A generator for the optional
migration existing apps run (concurrent index builds noted). Adjusted by
Task 1's findings.
**Acceptance criteria:**
- [ ] A fresh install has the new indexes; the optional migration turns a
      0.9 schema into the same one.
- [ ] The library's queries still use an index (checked with `EXPLAIN`).
**Verification:** migration tests against Postgres; `mix precommit`.
**Dependencies:** Task 1 checkpoint
**Scope:** S

### Checkpoint: Small changes
- [ ] `mix precommit` green.

### Phase 2: The doctor in production (F9)

#### Task 5: `PhxMediaLibrary.Doctor`
**Description:** Move the doctor's logic out of the mix task:
`check/1` (filters as the task's flags; media in batches) returns a
report; `repair/2` runs the repairs it is given; a telemetry event per
run. The mix task keeps its flags, output and prompt, and calls the
module.
**Acceptance criteria:**
- [x] `Doctor.check/1` and `repair/1` give the same results as the mix
      task, without Mix. (`repair/1` takes options and checks again as it
      goes, so it never holds a full list of problem media.)
- [x] Media is loaded in batches (no whole-table load).
- [x] `[:phx_media_library, :doctor, :check]` and `[..., :repair]`
      telemetry events with the counts.
**Verification:** doctor tests run against the module and the task;
`mix precommit`.
**Dependencies:** none
**Scope:** M

#### Task 6: The other maintenance tasks at runtime
**Description:** `clean`, `purge_deleted` and `stats`: logic into
functions (on `Doctor` or their own modules) where it isn't one already;
the tasks wrap them.
**Acceptance criteria:**
- [x] Each task's logic is callable without Mix and tested that way.
      (`Doctor.stats/1`, `purge_deleted/1`, `clean/1`.)
**Verification:** task tests; `mix precommit`.
**Dependencies:** Task 5
**Scope:** S

#### Task 7: `mix phx_media_library.gen.release`
**Description:** Generates a module in the app and a
`rel/overlays/bin/media_doctor` script that passes the mix task's flags,
the way `mix phx.gen.release` provides `bin/migrate`.
**Acceptance criteria:**
- [ ] The generated script runs the doctor in a release built from a
      generated Phoenix app (checked once by hand, steps recorded).
- [ ] Running the generator twice doesn't overwrite without asking.
**Verification:** generator tests; one manual release check; `mix precommit`.
**Dependencies:** Task 5
**Scope:** M

#### Task 8: The doctor on a schedule
**Description:** Per `docs/ideas/scheduled-doctor.md`: `:doctor_schedule`
config (off by default), runners `:oban` (a self-rescheduling unique job
in the app's queue), `:internal` (a process in the library's supervision
tree with a Postgres advisory lock) and `:auto`; a daily `at:` time; only
listed repairs, never `rename`, `fix` or `drop_originals`; batches with
pauses; startup checks.
**Acceptance criteria:**
- [ ] Disabled by default: no process, no job.
- [ ] Enabled: one run per day at `at:`, on one node, with only the
      allowed repairs; a missing Oban queue warns at startup.
- [ ] Each run emits the doctor's telemetry event.
**Verification:** scheduler tests with a controllable clock; Oban worker
tests; `mix precommit`.
**Dependencies:** Task 5
**Scope:** M

### Checkpoint: The doctor in production
- [ ] Review with Mike: the report shape, `bin/media_doctor` in a real
      release, the schedule config.

### Phase 3: Formats (F1)

#### Task 9: The `formats:` setting
**Description:** `formats:` globally, per collection and per conversion
(the conversion's wins); atoms or `{format, opts}` with quality, in order;
`:original`; default `[:webp]`; `avif: true` and a conversion's
`format: x` as shorthands. `Model` resolves it.
**Acceptance criteria:**
- [ ] Every combination resolves to the documented ordered list.
- [ ] Invalid formats are a clear configuration error.
**Verification:** model and config tests; `mix precommit`.
**Dependencies:** none
**Scope:** S

#### Task 10: Conversions in every listed format
**Description:** Each conversion is made in every resolved format;
`generated_conversions` records them in order; the safe (last) one is what
`relative_path/2` and `url/2` return; owned paths, delete, clean, rename
and the doctor cover all of them; records from 0.9 still resolve.
**Acceptance criteria:**
- [ ] `formats: [:avif, :webp]` stores `_thumb.avif` and `_thumb.webp`;
      `url(media, :thumb)` is the WebP.
- [ ] Delete, rename and the doctor handle both files; 0.9 records work.
**Verification:** conversion, doctor and path tests; `mix precommit`.
**Dependencies:** Task 9
**Scope:** M

#### Task 11: Variants and components in every listed format
**Description:** Responsive variants of the original and of conversions
in every listed format, recorded per format; shared variants (spec 01
F8) only within the same format list; `<.picture>`, `<.responsive_img>`
and `<.media_figure>` offer each format as a typed source, in order,
with the last as the `<img>`.
**Acceptance criteria:**
- [ ] With `[:avif, :webp]`, the srcset of each format lists only that
      format, and the `<img>` is WebP.
- [ ] With `[:webp]` (default), the markup is as in 0.9.
**Verification:** responsive and component tests; `mix precommit`.
**Dependencies:** Task 10
**Scope:** M

### Checkpoint: Formats
- [ ] Probe upload with `[:avif, :webp]`: file list and rendered markup
      reviewed with Mike.

### Phase 4: Bringing media in, and moving it

#### Task 12: Media from a binary, base64 or a stream (F3)
**Description:** `add/2` accepts `{:binary, data, filename}`,
`{:base64, data, filename}` and `{:stream, enumerable, filename}` (exact
shape decided in the task's tests), checked like any upload.
**Acceptance criteria:**
- [ ] Each source stores the same media as the same file from a path.
- [ ] Wrong content is refused as for uploads (type, size, pixels).
**Verification:** media adder tests; `mix precommit`.
**Dependencies:** none
**Scope:** S

#### Task 13: Minimum and maximum dimensions (F5)
**Description:** Collection options for minimum and maximum width and
height, validated with the other upload checks; tagged errors naming the
limit.
**Acceptance criteria:**
- [ ] Images outside the limits are refused with
      `{:error, {:image_too_small | :image_too_wide | ..., actual, limit}}`
      (names decided in the task).
**Verification:** validation tests; `mix precommit`.
**Dependencies:** none
**Scope:** S

#### Task 14: Copy and move media (F4)
**Description:** Copy a media item (new record, its own files) or move it
(same record, files follow) to another record or collection; the target
collection's rules apply; a move that breaks them is refused.
**Acceptance criteria:**
- [ ] A copy owns new files; deleting the original leaves the copy whole.
- [ ] A move keeps the record; files and URLs follow; limits enforced.
**Verification:** copy and move tests on disk and S3 (container);
`mix precommit`.
**Dependencies:** none
**Scope:** M

### Checkpoint: Bringing media in
- [ ] `mix precommit` green; API names reviewed with Mike.

### Phase 5: PDFs and Google Cloud Storage

#### Task 15: PDF thumbnails (F7)
**Description:** A document renderer behaviour with a libvips adapter
(when it can read PDFs) and a `pdftoppm` adapter (when installed),
detected at runtime like FFmpeg; a PDF's first page feeds its conversions,
placeholder and variants; without a renderer, PDFs are stored as today
and a warning is logged once.
**Acceptance criteria:**
- [ ] With a renderer, a PDF gets `:thumb` and a placeholder; the PDF
      itself stays the download.
- [ ] Without one, the upload succeeds and logs once.
**Verification:** tests with and without `pdftoppm` (skipped when
absent, like the S3 container tests); `mix precommit`.
**Dependencies:** none
**Scope:** M

#### Task 16: GCS research
**Description:** From Google's documentation: does the S3-compatible
(XML) API with HMAC keys cover put, get, delete, HEAD, ranged GET, signed
URLs and direct uploads (POST policy or signed PUT)? Is there an emulator
usable without an account? Result in `docs/ideas/gcs.md` with sources.
**Acceptance criteria:**
- [ ] A sourced capability table and a recommendation (preset or native
      adapter, and any new dependency).
**Verification:** review with Mike.
**Dependencies:** none
**Scope:** S

#### Task 17: Google Cloud Storage (F8)
**Description:** As Task 16 decided: a `provider: :gcs` preset of the S3
adapter, or a native adapter.
**Acceptance criteria:**
- [ ] Put, get, delete, public and signed URLs and a direct upload work
      against GCS or its emulator.
**Verification:** storage tests (container where possible); `mix precommit`.
**Dependencies:** Task 16 and Mike's review
**Scope:** M

### Checkpoint: PDFs and GCS
- [ ] `mix precommit` green; a PDF gallery checked in a browser.

### Phase 6: Waiting on the database numbers

#### Task 18: Processing status (F6)
**Description:** As the spike and Mike decide: proposed, three timestamps
per media job (`processing_started_at`, `processing_finished_at`,
`processing_failed_at` with the error), an optional migration, the status
derived; off without the columns or config.
**Acceptance criteria:** decided at the Measure checkpoint.
**Dependencies:** Task 1 checkpoint
**Scope:** M

#### Task 19: Bulk ingestion (F2)
**Description:** As the spike and Mike decide; builds on Task 12.
**Acceptance criteria:** decided at the Measure checkpoint.
**Dependencies:** Task 1 checkpoint, Task 12
**Scope:** M to L (split when specced)

### Checkpoint: Database features
- [ ] The spike's measurements rerun with the changes; reviewed with Mike.

### Phase 7: Docs and release

#### Task 20: Upgrade notes, README and guides (P2)
**Description:** `guides/upgrading-to-0.10.md` (each change from 0.9 and
how to adapt), README features, guides for every new feature, the
CHANGELOG's 0.10.0 section complete.
**Acceptance criteria:**
- [ ] Every spec 02 item appears in the CHANGELOG, a guide and, for
      features, the README.
- [ ] `mix docs` without warnings.
**Verification:** review with Mike.
**Dependencies:** all feature tasks
**Scope:** M

#### Task 21: Release preparation
**Description:** Version 0.10.0, dated CHANGELOG, zero warnings (as 0.9's
P5), `mix hex.build --unpack` check. Tag, push and publish only when
asked.
**Acceptance criteria:**
- [ ] `mix precommit` green; package contents checked.
**Verification:** the commands; Mike's go-ahead.
**Dependencies:** Task 20
**Scope:** S

### Checkpoint: Complete
- [ ] Every acceptance criterion in spec 02 is met.
- [ ] Ready for Mike to tag, push and publish.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| 0.10.0 keeps growing and never ships | High | Each phase ends green and could ship; Mike decides when to cut |
| Formats change the shape of `generated_conversions` and `responsive_images` again | High | Read every 0.9 shape (tests for each); the doctor rebuilds |
| The schedule hurts the app it runs in | High | Off by default, report only, one node, batches with pauses (`docs/ideas/scheduled-doctor.md`) |
| C2 stops variants for apps that relied on the global switch | Medium | Upgrade note: set `responsive: true` on the collection |
| GCS needs a new dependency | Medium | Research first; a preset needs none; Mike agrees to any dependency |
| `pdftoppm` missing in tests and deployments | Medium | Detect at runtime; tests skip without it; documented |
| Removals break 0.8 apps that skip 0.9 | Low | 0.9 on Hex carried the notices; upgrade notes name replacements |

## Open Questions

From the spec, decided at their checkpoints: bulk ingestion's shape, the
processing status design, SQLite (after Task 1); GCS preset or native
adapter (after Task 16).
