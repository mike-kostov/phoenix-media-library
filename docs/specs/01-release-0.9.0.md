# Spec 01: Release 0.9.0

Status: approved (Mike, 2026-10-04). Update of 2026-10-04 (S1 revised;
S4, S5, B7 and P4 added after the security checkpoint) approved the same
day.
Source: `docs/backlog.md` (0.9.0 section), `docs/ideas/placeholders.md`.

## Objective

0.9.0 makes the library safe by default, fast by default, and easy to keep
healthy, and the README says so. It is a minor release: it adds features and
changes some defaults, each listed in the CHANGELOG.

The user is a Phoenix developer attaching files to their schemas, and
through them the visitors of their pages. Success: an app upgrading from
0.8.x runs `mix phx_media_library.doctor`, follows its suggestions, and ends
up with safe uploads, small fast pages and no broken media, without
reading the source.

### Already done (in `[Unreleased]`, not specced again)

Scoped LiveView deletes and newest-wins collection limits; one place for
settings and processing steps (ADR-014); file naming strategies with
transliteration and alt text (ADR-015); the doctor with checks and repairs,
old repair tasks deprecated (ADR-016); preloaded media; `width`/`height`,
`sizes` and `priority` on image components; long-lived caching; editing alt
text and custom properties; `absolute_url/4`.

## Tech Stack

Elixir, Ecto (`ecto_sql`), Phoenix LiveView, Plug, Req. Optional: `:image`
(libvips), `ex_aws_s3` 2.5, `oban` 2.18, FFmpeg. No new required
dependency.

## Commands

```
Compile:    mix compile --warnings-as-errors
Test:       mix test                      (needs PostgreSQL; :db tests are skipped without it)
One file:   mix test test/phx_media_library/pipeline_test.exs
Gate:       mix precommit                 (format, credo --strict, dialyzer, test)
Types:      mix dialyzer
Docs:       mix docs
Package:    mix hex.build --unpack -o /tmp/pml-pkg
```

## Project Structure

```
lib/phx_media_library/              core modules (Model, Pipeline, Health, FileName, ...)
lib/phx_media_library/storage/      storage adapters (Disk, S3, Memory)
lib/phx_media_library/plug/         Plug.MediaDownload
lib/phx_media_library/components.ex, view_helpers.ex   shipped components
lib/mix/tasks/                      mix tasks (doctor, install, ...)
test/                               ExUnit tests; test/support for fixtures and test schemas
guides/                             HexDocs guides
docs/                               decisions, specs, plans, ideas, backlog (not shipped)
```

## Code Style

New processing work is a `Pipeline` step that resolves its settings through
`Model` and returns `{:ok, media}`, `{:skip, reason}` or `{:error, reason}`:

```elixir
@spec webp(Media.t(), keyword()) :: result()
def webp(%Media{} = media, opts \\ []) do
  settings = Model.webp_settings(target(media, opts), media.collection_name)

  cond do
    not Keyword.get(settings, :enabled, false) -> {:skip, :disabled}
    not Webp.convertible?(media.mime_type) -> {:skip, :not_convertible}
    true -> with_source(media, opts, &Webp.encode(media, &1, settings, storage, path))
  end
end
```

Coding rules: `.agents/rules/elixir-phoenix.md`. Prose: `unslop`.

## Testing Strategy

- ExUnit against PostgreSQL with `Ecto.Adapters.SQL.Sandbox`; DB tests are
  tagged `:db`.
- Real files in temporary directories; remote HTTP through Req's `plug:`
  option; components through `render_component/2`.
- Every bug fix and behaviour change starts with a test that fails on the
  old code.
- Default behaviour is tested without the library's own config (env removed
  and restored exactly).
- One test file per area; new files follow `test/phx_media_library/<area>_test.exs`.

## Boundaries

- Always: definition of done in AGENTS.md; one vertical slice per commit;
  run `mix precommit` before committing; update CHANGELOG, README and
  guides with each user-facing change.
- Ask first: database schema changes or migrations, new dependencies,
  changing a public function's contract beyond this spec, any behaviour
  change not listed here, pushing, tagging or publishing.
- Never: build storage paths from uploader input; break URLs of existing
  media; remove or weaken a failing test to make it pass; publish with
  failing tests or missing docs.

## Success Criteria

Each item lists acceptance criteria. An item is done when its criteria are
covered by tests (or, for docs, by review) and its slice is committed.

### Security

**S1. Direct-to-S3 uploads are enforced, per provider.** (behaviour change,
ADR-025)
- A disk's `direct_upload:` (`:post` or `:put`, defaulting from its
  provider preset: `:post` on AWS, `:put` elsewhere) decides the method.
- POST: a presigned POST whose policy makes the provider reject another
  key, a size over the limit (`:max_size`, else the collection's) or
  another content type. Done in task 4 for AWS.
- PUT: a presigned PUT whose signature covers the Content-Type; the server
  refuses to sign when the declared size is over the limit.
- `PhxMediaLibrary.presigned_upload/3` returns the method, URL, form fields
  or headers, and key; `presigned_upload_url/3` becomes a deprecated
  wrapper (removed in 0.10.0).
- `complete_external_upload/4` checks the object exists (HEAD), takes its
  size and content type from storage instead of the client, and validates
  them against the collection's `accepts` and `max_size`. An invalid object
  is deleted and the call returns `{:error, reason}`. Done in task 5.
- The media UUID is read correctly for every path generator. Done in
  task 5.
- The storage guide shows one client uploader for both methods.

**S2. SVG files can't run scripts.**
- The library provides a headers function for `Plug.Static`'s `:headers`
  option that serves `.svg` with
  `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox`
  and `X-Content-Type-Options: nosniff`, and leaves other files unchanged.
- `Plug.MediaDownload` sends the same headers for SVG.
- `mix phx_media_library.install` and the storage guide set it up.

**S3. No atoms from file extensions.**
- The image processor maps known extensions to formats and falls back to a
  default; uploading files with many unique extensions creates no atoms.

**S4. S3 adapter works with any S3-compatible provider.** (ADR-025)
- `provider: :aws | :r2 | :generic` on an S3 disk selects preset defaults;
  `endpoint:`, addressing, `base_url:`, `direct_upload:` and `acl:` override
  them, so unknown providers work as `:generic` plus settings.
- Requests and public URLs follow the endpoint; `:r2` builds it from
  `account_id:`.
- Verified against the test emulator (P4) for the operations the library
  uses; provider-specific rules come from `docs/ideas/s3-providers.md`.

**S5. Dependencies without known advisories.**
- The `req` requirement allows the latest stable release (0.7.4 at the time
  of writing), which fixes CVE-2026-49755 and CVE-2026-49756; the library's
  requests keep working, shown by the test suite.
- The lock file used for development and tests has no package with an
  advisory (`mix hex.audit`). Found while doing S5: `decimal`, `phoenix`,
  `phoenix_live_view` and `postgrex` were locked at affected versions; the
  library's requirements already allow the fixed ones, so apps are not
  held back.

### Bugs

**B1. URLs of media with special characters work.**
- URL helpers percent-encode each path segment, for disk and S3 public URLs.
  A media stored before 0.9 as `Report #3.pdf` is served at its URL.
- Signed download URLs still verify.

**B2. `consume_media/5` doesn't lose saved media.** (contract change)
- When every entry succeeds, the return is unchanged: `{:ok, media}`.
- When some fail, it returns `{:error, {:partial, saved_media, failed_entries}}`
  with each failure's reason, and the `:notify` messages report both. Code
  that already handles `{:error, _}` keeps working.

**B3. `Plug.MediaDownload` streams files.**
- Downloads use `send_file`; memory doesn't grow with file size.

**B4. Dead code removed** (`Process.delete` in
`MediaAdder.stream_and_checksum/3`).

**B6. Conversion files carry their format's extension.** (found while
planning)
- A conversion with `format:` (and, after F7, any conversion in a WebP or
  AVIF collection) is stored under its own format's extension, not the
  original's. Today `format: :webp` writes WebP bytes to `photo_thumb.jpg`.
- Media recorded before the fix keeps resolving to its old paths.

**B7. Uploads send no ACL by default.** (ADR-025)
- The S3 adapter sends an ACL header only when the disk sets `acl:`. Per
  AWS's documentation, uploads with `acl: private` fail on buckets with
  default settings, and R2 doesn't support ACL headers.

**B5. Placeholders without metadata.** Covered by F5; the tiny image no
longer carries EXIF or color profiles.

### Features

**F1. Downloads use the uploaded filename.** (behaviour change)
- `download: true` URLs (disk and S3) send `Content-Disposition` with
  `metadata["original_file_name"]`, falling back to `file_name`, with an
  ASCII fallback and a UTF-8 `filename*`.
- On disk, the name is covered by the URL signature, so it can't be changed.
  Unsigned download URLs keep the stored name.

**F2. `doctor --id`.**
- `mix phx_media_library.doctor --id <uuid>` checks and repairs one media
  item and combines with every repair flag.

**F3. AVIF.** (opt-in)
- `avif: true | [quality: ...]` globally and per collection, resolved by
  `Model`, generated by a `Pipeline` step next to the WebP for the served
  file. Responsive variants follow F6.
- `<.picture>` offers AVIF first, then WebP (when on), then the original.
- Skipped with a clear log line when libvips has no AVIF support.
- AVIF files are part of `owned_paths/1` (deleted, cleaned, renamed with the
  media), and the doctor reports and rebuilds them (`--rebuild --only avif`).

**F4. `<.media_figure>`.**
- Renders `<figure>` with the image and a `<figcaption>` from a `caption`
  attribute or `custom_properties["caption"]`; no caption, no figcaption.
- Accepts the image component options (`conversion`, `sizes`, `priority`,
  `class`, ...).

**F5. Placeholders on by default.** (behaviour change) Per
`docs/ideas/placeholders.md`:
- `placeholder: :blur | :color | false` globally (default `:blur`) and per
  collection.
- `:blur` is a 16px WebP without metadata (about 150 bytes); `:color` is the
  average color.
- Generated by a `Pipeline` step in the background (async processor), for
  every image and its conversions, stored in `responsive_images`; no
  migration.
- `media_img`, `responsive_img`, `picture`, `media_figure` and the gallery
  use it; images without one render without a placeholder.
- The doctor reports and repairs missing placeholders.
- Today's `tiny_placeholder` setting maps onto the new option.

**F6. Variants in one format only.** (ADR-024)
- Responsive variants are generated only in the best format that is on:
  AVIF, else WebP, else the original's format. No size exists in two
  formats.
- The full-size image keeps its fallback chain (AVIF, WebP, original), so
  browsers without AVIF still get an image, without size choice.

**F7. Conversions follow the served format.** (behaviour change, ADR-024)
- In a collection with WebP or AVIF on, conversions are saved in that format
  (AVIF over WebP) unless the conversion sets `format:` itself.
- `doctor --rebuild --only conversions` converts existing ones.

**F8. No duplicate variants for same-shape conversions.** (ADR-024)
- A conversion with the original's aspect ratio (width-only or height-only)
  gets no responsive variants of its own; its `srcset` uses the original's
  variants up to its own width, plus itself.
- Conversions with another shape (crops) keep their own variants.
- Measured on a 1600x1200 JPEG with `:preview` at 800px: its 160w and 320w
  variants were identical to the original's.

### Project

**P1. `mix precommit` passes on `main`.** The 16 `credo --strict` findings
and the unformatted `path_generator/tenant.ex` are fixed (ADR-022).

**P2. Docs and examples.**
- The README leads with the developer experience and features of 0.9.0,
  with short examples (uploads, naming, the doctor, page speed).
- Every guide matches 0.9.0; the migration notes list each behaviour change
  and how to keep the old behaviour where possible.
- The CHANGELOG announces the planned unification of responsive rules
  (ADR-017).

**P4. Real S3 in tests.** (ADR-026)
- S3 tests run against a reused Ministack container through Testcontainers
  in the normal `mix test`; `FakeS3Client` is gone.
- A project `.testcontainers.properties` makes it work with podman and
  Docker without per-machine settings.

**P3. Release.**
- The backlog is reviewed again; anything moved in is specced here first.
- `mix precommit` is green, `mix hex.build --unpack` contains no `docs/` or
  `.agents/`, the version is 0.9.0, the CHANGELOG section is dated.
- Tagging and publishing happen only when asked.

## Resolved Questions

1. B2 return shape: `{:error, {:partial, saved_media, failed_entries}}`,
   success unchanged (Mike, 2026-10-04).
2. F3 AVIF variants: replaced by F6, variants in one format only (Mike,
   2026-10-04).
3. F1 unsigned download URLs keep the stored name; documents should use
   signed URLs (Mike, 2026-10-04).
