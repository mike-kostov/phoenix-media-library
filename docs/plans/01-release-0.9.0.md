# Implementation Plan: Release 0.9.0

Spec: `docs/specs/01-release-0.9.0.md` (approved 2026-10-04)
Status: approved (Mike, 2026-10-04)
Decisions: ADR-014 to ADR-024

## Overview

Make the gate work first, then the security items (highest risk, fail
fast), then the bugs, then image formats (one variant format, conversions
in the served format, AVIF), then placeholders and the smaller features,
and finally docs and the release. Every task is one vertical slice and one
commit, verified by its own tests and `mix precommit`. A checkpoint with a
review closes each phase.

## Architecture Decisions

- **The gate comes first.** With no CI (ADR-022), every later commit relies
  on `mix precommit` passing, so the 17 credo findings and the unformatted
  file are fixed before anything else.
- **Conversion paths follow the conversion's format** (found while
  planning, a bug). A conversion with `format: :webp` today writes WebP
  bytes to `photo_thumb.jpg`, which browsers then reject as a JPEG under
  `nosniff`. `generated_conversions` records each conversion's extension,
  and `PathGenerator.relative_path/2` swaps the extension centrally, so
  custom path generators keep working. Legacy `true` values keep the
  original's extension. F7 depends on this.
- **Direct uploads are checked against real content.** Completion reads the
  object's size and first bytes from storage (a new optional storage
  callback; HEAD plus a ranged GET on S3) and runs the same validation as
  regular uploads.
- **Placeholders ride the existing background job.** When placeholders are
  on, the upload always enqueues background processing, even with no
  conversions; the job runs the placeholder step. No new job type.
- **AVIF reuses the WebP machinery.** The WebP encoder is generalised to a
  target format instead of a second, parallel module.

## Task List

### Phase 0: Gate

#### Task 1: Make `mix precommit` pass
**Description:** Fix the 17 `credo --strict` findings (nested module
aliases, nesting depth, complexity in `drop_originals`, `media_download`,
`s3`, `url_generator`, `ffmpeg`, `webp`, `blurhash`, `config`, and 3 test
files) and format `path_generator/tenant.ex`. Remove the dead
`Process.delete` in `MediaAdder.stream_and_checksum/3` (B4). No behaviour
change.
**Acceptance criteria:**
- [x] `mix precommit` exits 0 on a clean checkout.
- [x] No test changes besides the 3 alias fixes.
**Verification:** `mix precommit`; full suite count unchanged.
**Dependencies:** None
**Files:** the 11 flagged files, `media_adder.ex`
**Scope:** M (many files, mechanical)

### Checkpoint: Gate
- [x] `mix precommit` green; from here on it runs before every commit.

### Phase 1: Security

#### Task 2: No atoms from file extensions (S3)
**Description:** `ImageProcessor.Image` maps known extensions to formats
explicitly and falls back to a default.
**Acceptance criteria:**
- [x] Saving with 100 unique unknown extensions creates no new atoms.
- [x] Known formats (jpg, png, webp, avif, gif, tiff) still save correctly.
**Verification:** `mix test test/phx_media_library/image_processor_test.exs` (new); `mix precommit`.
**Dependencies:** Task 1
**Files:** `image_processor/image.ex`, new test
**Scope:** S

#### Task 3: Safe headers for SVG (S2)
**Description:** A headers function for `Plug.Static`'s `:headers` option
sets a sandboxing CSP and `nosniff` on `.svg`; `Plug.MediaDownload` sends
the same; the install task's endpoint snippet and the storage guide use it.
**Acceptance criteria:**
- [x] `Plug.Static` with the function serves `.svg` with
      `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox`
      and `X-Content-Type-Options: nosniff`; a `.jpg` gets neither CSP nor change.
- [x] `Plug.MediaDownload` sends the same headers for SVG.
- [x] Install task output and storage guide show the setup.
**Verification:** new plug tests; `mix precommit`.
**Dependencies:** Task 1
**Files:** new `plug/static_headers.ex`, `plug/media_download.ex`, `mix/tasks/phx_media_library.install.ex`, `guides/storage.md`, tests
**Scope:** M

#### Task 4: Presigned POST for direct uploads (S1, part 1)
**Description:** `Storage.S3.presigned_upload_url/3` creates a presigned
POST with conditions: exact key, `content-length-range` up to `:max_size`
(else the collection's `max_size`), and `Content-Type` when given.
`PhxMediaLibrary.presigned_upload_url/3` passes the collection limits.
**Acceptance criteria:**
- [x] The returned fields carry the policy with those conditions (decoded
      and asserted in tests).
- [x] `max_size` defaults to the collection's.
**Verification:** S3 adapter tests with a fixed `ExAws` config; `mix precommit`.
**Dependencies:** Task 1
**Files:** `storage/s3.ex`, `storage.ex` (docs), `phx_media_library.ex`, tests
**Scope:** M

#### Task 5: Completion verifies the stored object (S1, part 2)
**Description:** A new optional storage callback returns an object's size
and first bytes (S3: HEAD plus ranged GET; Disk and Memory: local).
`complete_external_upload/4` uses it: missing object is
`{:error, :not_found}`; size and detected type come from storage and are
validated against `accepts`, `max_size` and the type check; invalid objects
are deleted. The UUID is read as the file's parent folder, which holds for
all four path generators.
**Acceptance criteria:**
- [x] A missing object, an oversized object and a wrong-type object each
      return an error, and the latter two are deleted.
- [x] Size and MIME type stored on the media are the real ones, not the
      client's.
- [x] Completion works under Default, Flat, DateBased and Tenant paths.
**Verification:** tests with the Memory adapter (and a test adapter for the
callback contract); `mix precommit`.
**Dependencies:** Task 4
**Files:** `storage.ex`, `storage/s3.ex`, `storage/memory.ex`, `storage/disk.ex`, `phx_media_library.ex`, `milestone_3c_test.exs`
**Scope:** M (5 files)

### Checkpoint: Security
- [x] Full suite and `mix precommit` green.
- [x] Review with Mike (2026-10-04): accepted; R2 has no presigned POST, so
      the S3 approach became per provider (ADR-025) and real S3 tests were
      added (ADR-026). Phase 1b below.

### Phase 1b: S3 providers (spec update of 2026-10-04)

#### Task 5a: Req without advisories (S5)
**Description:** Allow the latest stable `req` (0.7.4) and adapt the
library's calls if its API changed.
**Acceptance criteria:**
- [x] `mix.lock` resolves `req` 0.7.4; `mix hex.audit` reports no advisory
      (also refreshed: ecto 3.14, decimal 3.1, phoenix 1.8.15,
      phoenix_live_view 1.2.12, postgrex 0.22.4).
- [x] Downloader, URL downloads and existing tests pass unchanged in
      behaviour (and a real HTTPS download through the pinned connection).
**Verification:** `mix hex.audit`; full suite; `mix precommit`.
**Dependencies:** Task 1
**Files:** `mix.exs`, `mix.lock`, possibly `downloader.ex`
**Scope:** S

#### Task 5b: Real S3 in tests, reached through `endpoint:` (P4, part of S4)
**Description:** The test helper starts a named Ministack container with
podman or Docker and reuses it on later runs (ADR-026, amended: no
Testcontainers). The S3 adapter takes
an `endpoint:` (scheme, host, port) and path-style addressing so it can
reach the container. Presign and `stat` tests move to a reused Ministack
container; `FakeS3Client` is removed.
**Acceptance criteria:**
- [x] S3 tests run in the normal `mix test` against Ministack; a second run
      reuses the container. (Cold 9.7 s, reused 7.3 s for the whole suite.)
- [x] Put, get, delete, exists, `stat`, signed URLs and presigned POST
      (policy enforced) work against the container through the adapter.
      Presigned PUT moves to Task 5e, where the adapter gains it.
- [x] No `FakeS3Client` remains.
**Verification:** full suite twice (timing of the second run); `mix precommit`.
**Dependencies:** Task 5a
**Files:** `test/support/ministack.ex`, `storage/s3.ex`, S3 tests, `test/test_helper.exs`
**Scope:** M

#### Task 5c: Provider presets and public URLs (S4)
**Description:** `provider: :aws | :r2 | :generic` sets defaults for
endpoint, addressing, public URL base, `direct_upload` and `acl`; disk
options override them. Public URLs follow the endpoint; `:r2` builds the
endpoint from `account_id:`.
**Acceptance criteria:**
- [x] Each preset resolves to the documented defaults; every option
      overrides its preset value.
- [x] Public URLs for `:r2` and `:generic` use their endpoint or `base_url:`,
      never `amazonaws.com`. (`:r2` needs `base_url:`, see spec S4.)
**Verification:** S3 config tests; container tests still pass; `mix precommit`.
**Dependencies:** Task 5b
**Files:** `storage/s3.ex`, `guides/storage.md`, tests
**Scope:** M

#### Task 5d: No ACL by default (B7)
**Description:** Upload requests carry an ACL header only when the disk sets
`acl:`.
**Acceptance criteria:**
- [x] Without `acl:`, put and multipart upload send no `x-amz-acl`
      (asserted on the request); with `acl:`, they send it.
**Verification:** S3 tests; `mix precommit`.
**Dependencies:** Task 5c
**Files:** `storage/s3.ex`, tests
**Scope:** S

#### Task 5e: Direct upload method per disk (S1 revision)
**Description:** `direct_upload: :post | :put` per disk (preset default).
New `PhxMediaLibrary.presigned_upload/3` returns `%{method, url, fields,
headers, key}`; PUT signs the Content-Type and is refused when the declared
size is over the limit. `presigned_upload_url/3` becomes a deprecated
wrapper. The storage guide shows one uploader for both methods; the
CHANGELOG's breaking-changes entry is rewritten to match.
**Acceptance criteria:**
- [x] A `:post` disk returns a policy as today; a `:put` disk returns a
      presigned PUT whose signed headers include `content-type`.
- [x] Declaring a size over the limit returns `{:error, {:file_too_large,
      size, max}}` without signing.
- [x] Both methods upload to the container end to end; completion accepts
      the object.
**Verification:** container tests for both methods; `mix precommit`.
**Dependencies:** Task 5d
**Files:** `storage/s3.ex`, `storage.ex`, `phx_media_library.ex`, `guides/storage.md`, `CHANGELOG.md`
**Scope:** M (5 files)

### Checkpoint: S3 providers
- [x] Full suite and `mix precommit` green; the second test run reuses the
      container.
- [x] Review with Mike: R2 configuration example and the uploader in the
      guide. (Approved to continue 2026-10-04; neither has run against a
      real R2 bucket or in a browser.)

### Phase 2: Bugs

#### Task 6: Percent-encoded URL paths (B1)
**Description:** URL helpers percent-encode each path segment for Disk and
S3 public URLs; signed URLs still verify.
**Acceptance criteria:**
- [x] A media stored as `Report #3.pdf` gets a URL that `Plug.Static`
      serves.
- [x] A signed download URL for that media verifies in `Plug.MediaDownload`.
**Verification:** URL and plug tests; `mix precommit`.
**Dependencies:** Task 1
**Files:** `storage/disk.ex`, `storage/s3.ex`, `url_generator.ex`, `plug/media_download.ex`, tests
**Scope:** M

#### Task 7: `consume_media/5` reports partial results (B2)
**Description:** Success stays `{:ok, media}`; when some entries fail it
returns `{:error, {:partial, saved, failed}}`, and `:notify` reports both.
**Acceptance criteria:**
- [x] With one failing entry of three, the two saved media are returned and
      the failure carries its reason.
- [x] All-success behaviour unchanged. (Tested through a real upload in
      `consume_media_test.exs`, with a test endpoint and LiveView.)
**Verification:** `live_upload_test.exs`; `mix precommit`.
**Dependencies:** Task 1
**Files:** `live_upload.ex`, `live_upload_test.exs`
**Scope:** S

#### Task 8: Streamed downloads (B3)
**Description:** `Plug.MediaDownload` serves files with `send_file` instead
of reading them into memory.
**Acceptance criteria:**
- [x] Download responses come from `send_file` (asserted via the conn);
      headers unchanged.
**Verification:** plug tests; `mix precommit`.
**Dependencies:** Task 3
**Files:** `plug/media_download.ex`, test
**Scope:** S

#### Task 9: Conversion files carry their format's extension (bug found in planning)
**Description:** `generated_conversions` records each conversion's
extension; `PathGenerator.relative_path/2` swaps the extension for
conversions that have one recorded; `true` (legacy) keeps the original's.
`owned_paths/1`, rename and the doctor follow automatically.
**Acceptance criteria:**
- [x] A conversion with `format: :webp` on a JPEG is stored as `…_thumb.webp`
      with WebP bytes, and its URL ends in `.webp`.
- [x] Media with `"thumb" => true` keeps resolving to `…_thumb.jpg`.
- [x] Delete, clean, rename and the doctor handle both.
**Verification:** conversion, path and doctor tests (fail first on the old
code); `mix precommit`.
**Dependencies:** Task 1
**Files:** `conversions.ex`, `path_generator.ex`, `media.ex`, tests
**Scope:** M

### Checkpoint: Bugs
- [x] Full suite and `mix precommit` green.

### Phase 3: Image formats

#### Task 10: Conversions in the served format (F7)
**Description:** Without an explicit `format:`, a conversion in a WebP
collection is saved as WebP (AVIF hook added in Task 11).
**Acceptance criteria:**
- [x] In `:webp_photos`, `:thumb` and `:preview` are WebP files.
- [x] An explicit `format: :png` still wins.
- [x] `doctor --rebuild --only conversions` converts existing JPEG
      conversions (tested through `Pipeline.conversions/2`, the step the
      doctor runs; the old file is removed).
**Verification:** pipeline and doctor tests; `mix precommit`.
**Dependencies:** Task 9
**Files:** `conversions.ex`, `model.ex`, tests
**Scope:** S

#### Task 11: AVIF generation (F3, part 1)
**Description:** `avif: true | [quality: …]` globally and per collection,
resolved by `Model`; the WebP encoder becomes format-generic; a `Pipeline`
step generates the AVIF of the served file on upload; skipped with a log
line when libvips lacks AVIF; conversions use AVIF over WebP (F7).
**Acceptance criteria:**
- [x] A collection with `avif: true` stores `custom_properties["avif"]`
      pointing at an AVIF file.
- [x] Off by default; collection setting overrides global.
- [x] Without AVIF support the upload succeeds and logs once.
      (README and guide coverage lands with Task 13, when `<picture>`
      serves the AVIF.)
**Verification:** pipeline tests; `mix precommit`.
**Dependencies:** Task 10
**Files:** `config.ex`, `collection.ex`, `model.ex`, `webp.ex`, `pipeline.ex`, `media_adder.ex`
**Scope:** L (6 files; split if it grows)

#### Task 12: AVIF through the media lifecycle (F3, part 2)
**Description:** AVIF files are owned paths (deleted, cleaned, renamed);
the doctor reports missing AVIF and rebuilds it (`--rebuild --only avif`).
**Acceptance criteria:**
- [x] Deleting, cleaning and renaming handle the AVIF file.
- [x] `Health.check/2` reports `:missing_avif`; the doctor repairs it.
**Verification:** media, doctor and health tests; `mix precommit`.
**Dependencies:** Task 11
**Files:** `media.ex`, `pipeline.ex`, `health.ex`, `doctor.ex`, tests
**Scope:** M

#### Task 13: Variants in one format, `<picture>` fallback (F6)
**Description:** Responsive variants use the best format on (AVIF, WebP,
original); the full-size `srcset` entry points at the best served file;
`<picture>` emits an AVIF source, then WebP, then the `img`.
**Acceptance criteria:**
- [x] With AVIF and WebP on, every variant is AVIF; no WebP variants exist.
- [x] `<picture>` renders sources in AVIF, WebP order with the right types.
      (`<.responsive_img>` becomes a `<picture>` when the media has an
      AVIF; decided with Mike 2026-10-04.)
**Verification:** responsive and component tests; `mix precommit`.
**Dependencies:** Task 12
**Files:** `responsive_images.ex`, `view_helpers.ex`, tests
**Scope:** M

#### Task 14: Same-shape conversions reuse the original's variants (F8)
**Description:** Conversions with the original's aspect ratio get no
variants of their own; their `srcset` (and the `width:` URL option) uses
the original's variants up to the conversion's width, plus the conversion.
**Acceptance criteria:**
- [x] The 1600x1200 JPEG with `:preview` at 800px produces no
      `preview_160w`/`preview_320w` files.
- [x] `srcset(media, :preview)` lists the original's 160w and 320w and the
      800w preview.
- [x] Crops (`:thumb`, `:banner`) keep their own variants.
**Verification:** responsive, URL and component tests; `mix precommit`.
**Dependencies:** Task 13
**Files:** `responsive_images.ex`, `conversions.ex`, `media.ex`, `url_generator.ex`, tests
**Scope:** M

### Checkpoint: Image formats
- [x] Full suite and `mix precommit` green.
- [x] Rerun the probe upload from the spec discussion and show Mike the
      file list for a WebP + AVIF + responsive collection. (Approved
      2026-10-04.)

### Phase 4: Placeholders and smaller features

#### Task 15: Placeholder step and settings (F5, part 1)
**Description:** `placeholder: :blur | :color | false` globally (default
`:blur`) and per collection, resolved by `Model`. A `Pipeline` step makes
a 16px WebP without metadata (blur) or the average color, for the original
and crop conversions, stored in `responsive_images`.
**Acceptance criteria:**
- [x] `:blur` placeholders are under 400 bytes on the sample photos and
      contain no EXIF or color profile. (235 photos measured, max 384
      bytes at 16px; tests use a generated photo with a color profile.
      The default became 32px after the browser review: median 260 bytes,
      max 776.)
- [x] `:color` stores a `#rrggbb` average color.
- [x] `false` stores nothing.
**Verification:** pipeline tests with real photos; `mix precommit`.
**Dependencies:** Task 14
**Files:** `config.ex`, `collection.ex`, `model.ex`, `pipeline.ex`, tests
**Scope:** M

#### Task 16: Placeholders in the background (F5, part 2)
**Description:** With placeholders on, the upload always enqueues
background processing (Task, Oban or Inline), even without conversions;
the job runs the placeholder step.
**Acceptance criteria:**
- [x] With the Inline processor, an upload to a collection without
      conversions ends with a placeholder.
- [x] The Oban worker runs the placeholder step for a job with no
      conversions.
**Verification:** async processor and Oban worker tests; `mix precommit`.
**Dependencies:** Task 15
**Files:** `media_adder.ex`, `conversions.ex`, `async_processor/oban.ex`, tests
**Scope:** M

#### Task 17: Components use placeholders (F5, part 3; B5)
**Description:** `media_img`, `responsive_img`, `picture` and the gallery
render the stored placeholder (background image or color); `tiny_placeholder`
maps onto the new setting; any remaining tiny-image generation strips
metadata.
**Acceptance criteria:**
- [x] Each component renders the blur or color placeholder when present
      and nothing when absent.
- [x] `tiny_placeholder: false` turns placeholders off as before.
**Verification:** component tests; `mix precommit`.
**Dependencies:** Task 16
**Files:** `view_helpers.ex`, `components.ex`, `responsive_images.ex`, `config.ex`, tests
**Scope:** M

#### Task 18: Doctor repairs placeholders (F5, part 4)
**Description:** `Health.check/2` reports `:missing_placeholder`;
`--regenerate` creates it.
**Acceptance criteria:**
- [x] Media uploaded before placeholders is reported and repaired.
**Verification:** health and doctor tests; `mix precommit`.
**Dependencies:** Task 17
**Files:** `health.ex`, `doctor.ex`, tests
**Scope:** S

#### Task 19: `<.media_figure>` (F4)
**Description:** Figure component with caption from attribute or
`custom_properties["caption"]`, passing image options through.
**Acceptance criteria:**
- [x] Renders `<figure>`, the image and `<figcaption>`; no caption, no
      figcaption.
- [x] `priority`, `sizes`, `conversion` and `class` reach the image.
**Verification:** component tests; `mix precommit`.
**Dependencies:** Task 17
**Files:** `view_helpers.ex`, tests
**Scope:** S

#### Task 20: Downloads use the uploaded filename (F1)
**Description:** `download: true` URLs send `Content-Disposition` with the
original name (ASCII fallback plus UTF-8 `filename*`); on disk the name is
part of the signed URL; S3 uses `response-content-disposition`; unsigned
download URLs keep the stored name.
**Acceptance criteria:**
- [x] A signed download of `Лятна рокля.pdf` sends both filename forms.
- [x] Changing the name in a signed URL fails verification.
- [x] S3 download URLs carry the original name.
**Verification:** URL, signed URL and plug tests; `mix precommit`.
**Dependencies:** Tasks 6 and 8
**Files:** `signed_url.ex`, `storage/disk.ex`, `storage/s3.ex`, `url_generator.ex`, `plug/media_download.ex`
**Scope:** M (5 files)

#### Task 21: `doctor --id` (F2)
**Description:** Limit the doctor to one media item; combines with every
repair flag.
**Acceptance criteria:**
- [x] `--id` checks and repairs only that media; an unknown ID reports
      clearly.
**Verification:** doctor tests; `mix precommit`.
**Dependencies:** Task 1
**Files:** `doctor.ex`, `doctor_test.exs`
**Scope:** S

### Checkpoint: Features
- [x] Full suite, `mix precommit` and `mix dialyzer` green.
- [x] Review with Mike: components on a product grid and a hero image,
      checked in a browser (placeholder blur assumption from the idea).
      (2026-10-04: 16px a bit blocky, 32px much better; 32px became the
      default with a size setting, and transparent images get none.)

### Phase 5: Docs and release

#### Task 22: README for 0.9.0 (P2)
**Description:** The README leads with the developer experience and
features, with short examples: uploads, file naming, the doctor, page speed
(placeholders, `width`/`height`, `sizes`, `priority`, caching, AVIF).
**Acceptance criteria:**
- [x] Every 0.9.0 feature appears in the feature list with an example or a
      link to its guide.
- [x] Prose passes `unslop`.
**Verification:** review with Mike.
**Dependencies:** Tasks 2 to 21
**Files:** `README.md`
**Scope:** S

#### Task 23: Guides and migration notes (P2)
**Description:** Update every guide for 0.9.0; add migration notes listing
each behaviour change (S1, F1, F5, F7, file naming, loading defaults, cache
fingerprint, doctor) and how to keep the old behaviour; announce the
responsive-rule unification (ADR-017) in the CHANGELOG.
**Acceptance criteria:**
- [x] No guide describes 0.8 behaviour as current. (Audited guide by
      guide against the CHANGELOG and the code.)
- [x] Each behaviour change has a migration note
      (`guides/upgrading-to-0.9.md`).
**Verification:** `mix docs` without new warnings; review with Mike.
**Dependencies:** Task 22
**Files:** `guides/*.md`, `CHANGELOG.md`
**Scope:** M

#### Task 24a: Zero warnings (P5)
**Description:** Fix every warning from compile, tests (including the
unused import in `direct_upload_test.exs`), docs (old CHANGELOG
references, the README's `LICENSE` link), credo and dialyzer.
**Acceptance criteria:**
- [x] `mix compile --force`, `mix test`, `mix docs`, `mix credo --strict`
      and `mix dialyzer` print no warnings. (Also `--warnings-as-errors`
      in dev and test, and `mix hex.build`.)
**Verification:** the commands above; `mix precommit`.
**Dependencies:** Task 23
**Scope:** S

#### Task 24b: HexDocs pass (P5)
**Description:** Group modules in the sidebar, hide internal modules,
check every public module's docs for an example, document the
placeholder-settings limit in the placeholders and doctor docs, link the
README to HexDocs where it helps.
**Acceptance criteria:**
- [x] The sidebar groups modules; internal modules don't appear.
      (Internal building blocks the CHANGELOG already names, such as
      `Webp` and `MediaAdder`, are grouped under "Internals" instead of
      hidden, so their links keep working.)
- [x] Every public module has a `@moduledoc` with an example.
**Verification:** `mix docs` and a look at the output; review with Mike.
**Dependencies:** Task 24a
**Scope:** M

#### Task 24c: AVIF compatibility spike (P5)
**Description:** Research with sources which browsers (desktop and mobile),
Googlebot and AI tools read AVIF; record it in `docs/ideas/`. Bring any
finding that changes ADR-024 (conversions in AVIF) to Mike first.
**Acceptance criteria:**
- [x] An idea doc with a sourced support table and a recommendation.
      (`docs/ideas/avif-compatibility.md`; led to Task 24e.)
**Verification:** review with Mike.
**Dependencies:** none
**Scope:** S

#### Task 24d: Media table index spike (P5)
**Description:** Fill a Postgres database with 15 models and about 10,000
media each; run the library's queries (`get_media`, ordering, the doctor's
loads, preloads) with `EXPLAIN ANALYZE`; record the plans and timings.
**Acceptance criteria:**
- [x] An idea doc with the plans and a recommendation (keep, add or drop
      indexes); a migration only with Mike's agreement.
**Verification:** review with Mike.
**Dependencies:** none
**Scope:** M

#### Task 24e: Safe formats (F7a, ADR-024 amendment)
**Description:** Conversions default to WebP in every collection and are
never AVIF unless asked; AVIF only for the original and its variants,
inside `<picture style="display: contents">`; conversion variants follow
the conversion's format; same-shape reuse only within one format; upgrade
notes, guides and CHANGELOG updated.
**Acceptance criteria:**
- [x] In a collection without `webp:`, `:thumb` is a WebP file;
      `format: :original` keeps the original's format.
- [x] In an AVIF collection, no conversion or conversion variant is AVIF,
      and no `<img src>` or plain URL points at an AVIF file.
- [x] `<.responsive_img>` with AVIF renders
      `<picture style="display: contents">`.
- [x] A WebP conversion doesn't reuse AVIF or JPEG variants of the
      original.
**Verification:** conversion, responsive and component tests; `mix precommit`.
**Dependencies:** Tasks 24c, 24d
**Scope:** M

#### Task 24: Release preparation (P3)
**Description:** Review the backlog again with Mike, set the version to
0.9.0, date the CHANGELOG section, check the package. Tag and push only
when asked; 0.9.0 is not published to Hex (Mike, 2026-10-04), work
continues on 0.10.0.
**Acceptance criteria:**
- [x] `mix precommit` green; `mix hex.build --unpack` has no `docs/` or
      `.agents/`.
- [x] Version and CHANGELOG say 0.9.0 with the release date.
**Verification:** commands above; Mike's go-ahead.
**Dependencies:** Tasks 23, 24a to 24e
**Files:** `mix.exs`, `CHANGELOG.md`, `docs/backlog.md`
**Scope:** S

### Checkpoint: Complete
- [x] Every acceptance criterion in spec 01 is met. (Index changes moved
      to 0.10.0 by Mike; the `formats:` list too.)
- [ ] Ready for Mike to tag and push (no Hex publish, per Mike).

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| S1 changes how apps upload to S3 (POST form instead of PUT) | High | Migration note with the client-side code; clear error when an app still PUTs; review at the security checkpoint |
| Task 9 changes the shape of `generated_conversions` values | Medium | Read `true` as before; tests for both shapes; doctor covers mixed libraries |
| libvips builds without AVIF | Medium | Detect at runtime, skip with one log line, test both paths |
| F8 touches `srcset` and the `width:` URL option | Medium | Tests for both before changing; compare output on the probe upload |
| Placeholder jobs for collections without conversions change Oban job behaviour | Medium | Worker tests for empty conversion lists |
| Task 11 grows past one session | Low | Split encoder generalisation from settings if it does |
| Scope keeps growing (bugs found go into 0.9.0) | Medium | New items get a spec section and a task here before work starts |

## Open Questions

- Placeholders for same-shape conversions: reuse the original's placeholder
  (consistent with F8) instead of generating one per conversion. Proposed:
  yes, decided in Task 15 unless Mike objects.
