# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.1] - 2026-08-20

### Added

- **Responsive WebP variants.** Responsive `srcset` variants now inherit the
  served format. When a collection serves WebP, its variants are written to
  `.webp` paths and encoded as WebP (the image backend picks the encoder from
  the destination extension), and the full-size `srcset` descriptor reuses the
  already-generated WebP sibling, so the entire `srcset` is WebP at no extra
  cost. Non-WebP collections keep the original extension, unchanged.
- **Per-collection responsive opt-in.** A collection enables `srcset`
  generation on add via its `responsive:` field (bool or keyword), with widths
  overridable per-collection:

  ```elixir
  media_collections do
    collection(:photos,  webp: true, responsive: true)                    # WebP variants, global widths
    collection(:banners, webp: true, responsive: [widths: [640, 1280, 2560]])
  end
  ```

  `PhxMediaLibrary.ResponsiveImages.generate/3` gains an optional `widths:`
  option (defaults to the global config), so per-collection widths flow through
  the add pipeline.

### Changed

- On add, WebP generation now runs before responsive generation, so
  variants inherit the `.webp` encoding.
- Responsive generation on add is opt-in per collection (`responsive:`) or
  via `with_responsive_images/1`. Unlike WebP, the global `responsive_images`
  config is not treated as an auto-enable for every collection. It supplies
  the default widths only. This preserves the historical behaviour where only an
  explicit request generated variants (no surprise generation for existing hosts
  that had `responsive_images: [enabled: true]`).

### Fixed

- Responsive variant paths now derive from the configured path generator
  instead of assuming the default `{type}/{id}/{uuid}` layout. This respects
  custom/tenant/date generators and stringifies a non-binary
  `mediable_id` (e.g. an integer primary key). Previously `Path.join` raised
  when the id was not already a string.

## [0.8.0] - 2026-08-20

### Added

- **WebP conversion.** A collection can transcode raster/HEIC uploads to WebP
  for faster loads and better SEO. Opt in globally or per-collection; every knob
  is overridable per-collection:

  ```elixir
  config :phx_media_library,
    webp: [enabled: false, quality: 82, keep_original: true]

  media_collections do
    collection(:photos, webp: true)                        # jpg/png/HEIC → served as WebP
    collection(:hero,   webp: [quality: 90, keep_original: false])
  end
  ```

  With `keep_original: true` (default) the source is kept; `false` removes it,
  but only after conversions run (conversions derive from the source, so
  they are generated first and the deletion is strictly last; safe to combine
  with named conversions). Either way `url/2` serves the WebP via
  `custom_properties["webp"]`, so `<img src>` needs no change.
  Requires the optional `:image` (libvips) dependency; features no-op
  when it is absent, and any conversion error falls back to serving
  the original. iPhone HEIC/HEIF uploads convert to browser-viewable
  WebP.
- `mix phx_media_library.regenerate_webp` re-derives WebP from each media's
  original using the current config (run after changing `quality`). Media stored
  with `keep_original: false` have no source and are skipped with a warning.
- `PhxMediaLibrary.Config.resolve_webp/1` and `resolve_responsive/1` resolve
  effective per-collection settings (per-collection over global over defaults).
- `PhxMediaLibrary.AsyncProcessor.Inline` is a synchronous conversion processor
  (runs conversions inline, no `Task.Supervisor`); handy for tests, scripts, or
  small apps. Enable with
  `config :phx_media_library, async_processor: PhxMediaLibrary.AsyncProcessor.Inline`.

### Fixed

- Conversions now tolerate their media changing between enqueue and
  processing. `Conversions.process/2` re-reads the current row (skipping if the
  media was deleted), so it avoids `Ecto.StaleEntryError` on the async path.
- Conversions no longer crash (`Image.open(nil)` → `Enumerable not implemented`)
  on disks without a local source path (`:memory`, S3). `process/2` and
  `process_single/2` skip (debug-logged) when `full_path` is `nil`.

### Notes

- WebP is opt-in; upgrading from 0.7.x changes nothing until a collection
  enables it.
- With `keep_original: false`, `file_name`/`mime_type` still describe the source
  (the WebP is served via `custom_properties["webp"]`); the source file is
  removed after conversions. `regenerate_webp` skips such media (no source).

## [0.7.0] - 2026-08-09

### Added

- **Configurable `mediable_id_type`.** The `mediable_id` field in the `Media`
  schema now comes from `Application.compile_env(:phx_media_library,
  :mediable_id_type, :binary_id)`. Supported values are `:binary_id` (default,
  no change for existing installs), `:integer`, and `:string`. This lets
  `PhxMediaLibrary` associate media with models whose primary key is not a
  UUID, while remaining backwards-compatible with existing applications.

- `Config.mediable_id_type/0` returns the resolved compile-time value.

- **Path generators coerced to string.** `Default`, `DateBased`, and `Tenant`
  path generators now call `to_string/1` on `mediable_id` before passing it to
  `Path.join/1`, so integer and non-string IDs no longer raise
  `FunctionClauseError`.

- `mix phx_media_library.install --id-type` is a new install flag that accepts
  `binary_id` (default), `integer`, or `string`, and generates the migration
  with the matching column type for `mediable_id` (`:binary_id`, `:bigint`, or
  `:string`). The `--binary-id false` shorthand is still accepted for backwards
  compatibility and maps to `--id-type integer`.

### Upgrade notes

The current default for `mediable_id_type` is `:binary_id` to keep all
existing installations working without any configuration change. In 0.8 the
default will change to `:string`. New apps should set
`config :phx_media_library, mediable_id_type: :string` today; they will
require no change when upgrading to 0.8. Existing apps that omit the key and
rely on the `:binary_id` default should add `mediable_id_type: :binary_id`
explicitly before upgrading to 0.8.

## [0.6.0] - 2026-03-31

### Added

#### 4.1 BlurHash Generation

- `PhxMediaLibrary.Blurhash` is a new module that generates BlurHash strings
  from image files. Uses the `:image` library (libvips) to resize images to a
  small working size and applies a pure-Elixir DCT encoder (base-83 alphabet,
  reference: blurha.sh). Optional. Disabled when `:image` is not
  installed.

- `Config.blurhash_enabled?/0` returns `true` when
  `responsive_images: [blurhash: true]` is configured and the `:image`
  library is available.

- **Automatic blurhash generation.** `MediaAdder` now generates a BlurHash
  string for every image upload when `blurhash_enabled?/0` is true and stores
  it in `media.responsive_images["blurhash"]`.

- `Media.blurhash/1` and `PhxMediaLibrary.blurhash/1` are convenience
  helpers that return `media.responsive_images["blurhash"]` or `nil`.

- `<PhxMediaLibrary.Components.blurhash>` is a new function component that
  renders the hash as a `<canvas>` element. A colocated JavaScript hook
  (no npm dependency) decodes the hash client-side and paints the blurred
  preview for progressive loading before the real image arrives.

#### 4.4a CDN URL Generation with Cache-Busting

- **`url/3` `:cache_bust` option.** Pass `cache_bust: true` to any
  URL-generating call to append `?v={checksum[0..7]}` to the URL. The
  fingerprint comes from the media item's stored SHA-256 checksum, so CDN
  edges serve a fresh copy whenever a file is replaced. Falls
  back to a plain URL when no checksum is stored.

- `PhxMediaLibrary.cdn_url/2`, `Media.cdn_url/2`, and
  `UrlGenerator.cdn_url/2` are convenience shorthand for
  `url(media, conversion, cache_bust: true)`.

#### 4.4b Content-Disposition Download Links

- **`url/3` `:download` option.** Pass `download: true` to generate a URL
  that triggers `Content-Disposition: attachment` in the browser.

  - **S3.** Generates a presigned GET URL with the
    `response-content-disposition` query parameter included in the AWS
    Signature V4 canonical request (so the signature is valid).
  - **Local disk.** Routes through `PhxMediaLibrary.Plug.MediaDownload`,
    which serves the file with the proper response header.

- `PhxMediaLibrary.download_url/3`, `Media.download_url/3`, and
  `UrlGenerator.download_url/3` are shorthand for
  `url(media, conversion, download: true)`.

- `PhxMediaLibrary.Plug.MediaDownload` is a new Plug for local-disk
  storage. Mount it in the Phoenix router at the path configured as
  `download_base_url`. Supports unsigned download links and HMAC-signed
  expiring URLs (see 4.4c below). Includes path-traversal protection.

#### 4.4c Signed / Expiring URLs

- **`url/3` `:signed` and `:expires_in` options.** Pass `signed: true` to
  generate a time-limited URL. `:expires_in` controls the expiry window in
  seconds (default: `3600`).

  - **S3.** AWS Signature V4 presigned GET URL (already supported internally;
    now exposed through the `url/3` API).
  - **Local disk.** HMAC-SHA256-signed URL that
    `PhxMediaLibrary.Plug.MediaDownload` verifies. Requires `secret_key_base` and
    `download_base_url` in the disk config.

- `PhxMediaLibrary.signed_url/3`, `Media.signed_url/3`, and
  `UrlGenerator.signed_url/3` are shorthand for
  `url(media, conversion, signed: true)`.

- `PhxMediaLibrary.SignedUrl` is a new module that implements HMAC-SHA256
  signing and constant-time verification for local-disk URLs.

- `Config.secret_key_base/0` and `Config.download_base_url/0` are
  new config helpers for the global signing secret and download plug mount
  path.

#### 4.3 Multi-Tenant Support

- `PhxMediaLibrary.PathGenerator.Tenant` is a new built-in path generator
  that prepends a `tenant_id` segment to every storage path:
  `{tenant_id}/{mediable_type}/{mediable_id}/{uuid}/{filename}`. It reads the
  `tenant_id` from the optional `path_context` map (atom or string
  key); falls back to `"shared"` when absent. It coerces integer IDs to
  strings.

- The Multi-Tenant guide (`guides/multi-tenant.md`) covers natural
  per-model scoping, configuring `PathGenerator.Tenant`, passing
  `path_context` through upload flows, cross-model queries, per-tenant
  storage backends, custom generators, and migrating existing files.

- `Config.path_generator/0` doc updated to list `Tenant` alongside
  `Default`, `Flat`, and `DateBased`.

#### 4.2 Optional FFmpeg Video Processor

- `PhxMediaLibrary.VideoProcessor` behaviour is a new pluggable behaviour
  for video processing adapters with three callbacks: `available?/0`,
  `extract_metadata/1`, and `extract_poster/2`.

- `PhxMediaLibrary.VideoProcessor.FFmpeg` is an implementation that uses
  `ffprobe` (metadata) and `ffmpeg` (poster frames). Selected when both
  executables are on `$PATH`. No configuration required.
  Extracts: `duration` (float seconds), `width`, `height`, `codec`, `fps`,
  `audio_codec`, `bit_rate`.

- `PhxMediaLibrary.VideoProcessor.Null` is a no-op fallback used when
  FFmpeg is not installed. Uploads still succeed; metadata and poster
  generation are skipped without errors.

- `Config.video_processor/0` returns the active video processor
  module; auto-detects FFmpeg at startup; configurable via
  `config :phx_media_library, video_processor: …`

- **Automatic video metadata extraction.** `MetadataExtractor.Default`
  now delegates video file extraction to the configured `VideoProcessor`
  and populates `media.metadata` with duration, dimensions, codec, and fps on
  every video upload when FFmpeg is available.

- **Poster frame generation.** `MediaAdder` extracts a JPEG poster frame
  at 10% into the video (capped at 5 s) after upload and stores
  it alongside the video file. It records the URL in
  `media.responsive_images["poster"]["url"]` for use in templates.

- `<.media_video>` component is a new `PhxMediaLibrary.Components`
  function component that renders a styled `<video>` player with automatic
  poster frame, preload, and a metadata strip (duration, dimensions, codec,
  fps). Accepts `controls`, `autoplay`, `muted`, `loop`, and `class`
  attributes.

### Fixed

- **`delete_files/1` crash on media with responsive images.** The
  responsive images delete loop incorrectly pattern-matched
  `%{"path" => path}` directly on top-level map values, which are actually
  `%{"variants" => [...], "placeholder" => ...}` structs. The loop now
  uses multi-clause `Enum.each` to handle both responsive image
  variant lists and poster frame entries (`%{"path" => ..., "url" => ...}`).

- **`data-confirm` interpolation in gallery_app video delete button.**
  The confirmation string used unescaped curly quotes around the filename,
  which caused a HEEx compile warning. Now uses proper `\"` escaping.

### Changed

- Version bumped to `0.6.0`. Covers the full Milestone 4 feature set
  (4.2 FFmpeg video processing, 4.3 multi-tenant path generator, 4.4/4.5/4.6
  tooling and path generators delivered in Wave 1).

## [0.5.1] - 2026-03-01

### Added

- **Nested `collection ... do` DSL for conversions.** You can now nest `convert` calls inside a `collection ... do ... end` block within `media_collections`. The DSL scopes each conversion to the enclosing collection, so you need not pass `:collections` manually. This is now the recommended style:

  ```elixir
  media_collections do
    collection :images, max_files: 20 do
      convert :thumb, width: 150, height: 150, fit: :cover
      convert :preview, width: 800, quality: 85
    end

    collection :documents, accepts: ~w(application/pdf)

    collection :avatar, single_file: true do
      convert :thumb, width: 150, height: 150, fit: :cover
    end
  end
  ```

  You can mix the nested and flat styles. The DSL respects explicit `:collections` options inside nested blocks. See the updated [Collections & Conversions](guides/collections-and-conversions.md) guide for details.

- `PhxMediaLibrary.ModelRegistry` is a new always-compiled module that discovers and caches the Ecto schema module for a given `mediable_type` string. Previously this logic lived inside `PhxMediaLibrary.Workers.ProcessConversions` (which is only compiled when Oban is installed), which caused warnings in the `mix phx_media_library.regenerate` task for projects without Oban. Both the Oban worker and the mix task now delegate to `ModelRegistry`.

- `PhxMediaLibrary.MediaLive` LiveComponent is a self-contained LiveComponent that encapsulates the entire media upload + gallery lifecycle. Eliminates all upload boilerplate: no `use PhxMediaLibrary.LiveUpload`, no `handle_event` clauses, no `allow_upload`, no `consume_media`. Just drop it into any LiveView template:

  ```elixir
  <.live_component
    module={PhxMediaLibrary.MediaLive}
    id="post-images"
    model={@post}
    collection={:images}
  />
  ```

  Features: drag-and-drop upload zone, live image previews, progress bars, error display, cancel buttons, submit button, stream-powered media gallery with delete-on-hover, dark mode support. Configurable via `max_file_size`, `max_entries`, `responsive`, `upload_label`, `upload_sublabel`, `compact`, `columns`, `conversion`, `show_gallery`, and `class` options.

  Sends `{PhxMediaLibrary.MediaLive, {:uploaded, collection, media_items}}` and `{PhxMediaLibrary.MediaLive, {:deleted, collection, media}}` messages to the parent LiveView for optional reaction.

- **Restructured LiveView guide.** Now leads with the zero-boilerplate `MediaLive` LiveComponent approach, with a dedicated "Custom Upload UI" section documenting how to build your own form with `<.live_file_input>` for full control. Includes a warning about the nested form gotcha with `<.media_upload>`.

- The `upload_class`, `gallery_class`, `button_class` options for `MediaLive` let consumers override the default Tailwind utility classes on the drop zone wrapper, gallery grid container, and submit button respectively. When `nil` (default), MediaLive uses the built-in styles. When set, the value replaces the default classes, so you can integrate with component libraries like daisyUI (e.g. `button_class="btn btn-primary w-full"`).

### Fixed

- **Eliminated noisy ExAws/S3 compile warnings in consumer projects.** `PhxMediaLibrary.Storage.S3` is now wrapped in `if Code.ensure_loaded?(ExAws.S3) do`, the same pattern `ImageProcessor.Image` and `AsyncProcessor.Oban` already use. Consumer projects that don't use S3 will no longer see ~15 `ExAws.S3.* is undefined` warnings during compilation.

- **Eliminated `ProcessConversions.find_model_module/1 is undefined` warning.** The `mix phx_media_library.regenerate` task previously referenced `PhxMediaLibrary.Workers.ProcessConversions`, which only exists when Oban is installed. The model lookup logic has been extracted into `PhxMediaLibrary.ModelRegistry` (always compiled), and the Oban worker now delegates to it. `ProcessConversions.find_model_module/1` remains as a `defdelegate` for backwards compatibility.

- **Multi-file selection now works by default.** Non-`single_file` collections without an explicit `max_files` now default to `max_entries: 10`, which enables the `multiple` attribute on the file input. Previously, `max_entries` was left unset, which caused Phoenix LiveView to default to 1 (single file picker). Collections with `single_file: true` still limit to 1, and `max_files: N` still maps to `max_entries: N`.

- **Upload progress bars are now visible on fast/local uploads.** The component now renders the progress bar track as soon as a file is selected (`progress >= 0`) instead of only when `progress > 0`. On local development, uploads complete almost instantly so the previous `> 0 && < 100` condition meant the bar was never visible. The bar now shows a subtle track at 0%, fills with blue as progress advances, displays a percentage label, and transitions to a "Ready" checkmark at 100%.

### Changed

- **Updated all documentation to recommend nested DSL.** The `HasMedia` moduledoc, getting-started guide, and collections-and-conversions guide now show the nested `collection ... do convert ... end` style as the primary/recommended approach, with the flat style and function-based approach as alternatives. All examples explicitly scope conversions to collections.

- The LiveView guide's "How Upload Limits Are Derived" section documents how `max_entries` is derived from collection configuration (`single_file: true` → 1, `max_files: N` → N, otherwise 10) and how the `max_entries` component option overrides it.

- The LiveView guide's "Customizing Styles" section documents the `upload_class`, `gallery_class`, and `button_class` options with examples for daisyUI integration and custom styling.

## [0.5.0] - 2026-02-27

### Added

- **Milestone 3c complete** (717 tests passing, up from 653 in v0.4.0)

#### 3.5 Soft Deletes

- **Opt-in soft deletes.** `config :phx_media_library, soft_deletes: true` enables soft deletes globally. Disabled by default, no behaviour change for existing users
- **`delete/1` respects config.** When soft deletes are enabled, `delete/1` sets `deleted_at` instead of removing the record and files. When disabled, behaviour is unchanged (hard delete)
- `permanently_delete/1` always performs a hard delete (removes files from storage and database record) regardless of the soft deletes configuration
- `soft_delete/1` soft-deletes a media item by setting its `deleted_at` timestamp. Files are preserved in storage until `permanently_delete/1` or `purge_trashed/2` is called
- `restore/1` restores a soft-deleted media item by clearing `deleted_at`
- `trashed?/1` is a predicate to check whether a media item has been soft-deleted
- `get_trashed_media/2` queries only soft-deleted media for a model, optionally filtered by collection (inverse of `get_media/2`)
- `purge_trashed/2` permanently deletes all trashed media for a model, with optional `:before` cutoff for age-based cleanup (e.g. `before: DateTime.add(DateTime.utc_now(), -30, :day)`)
- **Query scoping.** `get_media/2`, `get_first_media/2`, `media_query/2`, and `Media.for_model/2` exclude soft-deleted records when soft deletes are enabled
- `exclude_trashed/1` and `only_trashed/1` are query helpers on `Media` for composing custom Ecto queries
- **`clear_collection/2` and `clear_media/1` respect soft deletes.** When enabled, these set `deleted_at` via `update_all` instead of deleting records. Files are preserved until purge
- `mix phx_media_library.purge_deleted` is a Mix task to permanently remove old soft-deleted media. Options: `--days N` (default: 30), `--all`, `--dry-run`, `--yes`
- **New migration.** `add_deleted_at_to_media` adds `deleted_at` column with index
- **Install task updated.** `mix phx_media_library.install` now includes `deleted_at` column and index from the start

#### 3.6 Streaming Upload Support

- **File streaming.** `MediaAdder` no longer loads entire files into memory via `File.read!`. It streams files to storage in 64 KB chunks with `File.stream!/2`
- **Single-pass checksum.** `MediaAdder` computes the SHA-256 checksum during the stream (via `Stream.map/2` feeding `:crypto.hash_update/2`) instead of in a separate full-file read
- **Header-only MIME detection.** The detector reads only the first 512 bytes for magic-byte MIME type detection, enough for all supported formats (including TAR at offset 257)
- **Known issue resolved.** "MediaAdder loads entire file into memory" is no longer applicable

#### 3.7 Direct S3 Upload (Presigned URLs)

- `presigned_upload_url/3` generates a presigned URL for direct client-to-S3 uploads. Returns `{:ok, url, fields, upload_key}`. Requires `:filename` option; supports `:content_type`, `:expires_in`, `:max_size`
- `complete_external_upload/4` creates a `Media` database record after the client uploads directly to storage. Requires `:filename`, `:content_type`, `:size`; supports `:custom_properties`, `:checksum`, `:checksum_algorithm`
- **`presigned_upload_url/3` callback.** New optional callback on `PhxMediaLibrary.Storage` behaviour. The S3 adapter implements it; Disk and Memory adapters return `{:error, :not_supported}`
- `StorageWrapper.presigned_upload_url/3` is an adapter-aware wrapper that checks `function_exported?/3` and returns `{:error, :not_supported}` for adapters without the callback
- **Telemetry.** `complete_external_upload/4` emits `[:phx_media_library, :add, :start | :stop]` events with `source_type: :external`

### Changed

- **`MediaAdder.store_and_persist/6` → `store_and_persist/5`.** No longer receives `file_content` as a parameter. `MediaAdder` computes the checksum during streaming
- `MediaAdder.read_and_detect_mime/1` now reads only the first 512 bytes (header) instead of the entire file. Returns `{:ok, file_info, header}` instead of `{:ok, file_info, file_content}`
- **`Media.delete/1` return type.** Returns `{:ok, media}` when soft deletes are enabled (soft delete), or `:ok` when disabled (hard delete)
- **`Media` schema.** Added `deleted_at` field (`:utc_datetime`, default `nil`)
- `Media.permanently_delete/1` renamed from the previous `delete/1` hard-delete implementation. `delete/1` now dispatches based on soft deletes config
- **`PhxMediaLibrary.Storage` behaviour.** Added optional `presigned_upload_url/3` callback
- **Install task migration template.** Now includes `deleted_at` column and index

## [0.4.0] - 2026-02-27

### Added

- **Milestone 3b complete** (653 tests passing, up from 529 in v0.3.0)

#### 3b.1 Remote URL Sources (Enhanced)

- **URL validation.** `add_from_url/3` now validates URL scheme (only `http`/`https` allowed), rejects missing hosts, and returns `{:error, {:invalid_url, reason}}` tuples for `ftp://`, `file://`, or malformed URLs
- **Custom request headers.** `add_from_url/3` accepts `:headers` option for authenticated downloads (e.g. `headers: [{"Authorization", "Bearer token"}]`)
- **Download timeout.** `:timeout` option sets a receive timeout for slow servers
- **Download telemetry.** New `[:phx_media_library, :download, :start | :stop | :exception]` events with URL, size, and MIME type metadata
- **Source URL tracking.** When media is added from a URL, the original URL is stored in `custom_properties["source_url"]`
- **Broader success codes.** Downloads now accept any 2xx status code (200-299), not only 200

#### 3b.2 Automatic Metadata Extraction

- `PhxMediaLibrary.MetadataExtractor` is a new behaviour for extracting file metadata with `extract/3` callback
- `PhxMediaLibrary.MetadataExtractor.Default` is the default implementation that:
  - Extracts image dimensions (`width`, `height`), alpha channel presence, and EXIF data via the `:image` library (when available)
  - Classifies files into type categories: `"image"`, `"video"`, `"audio"`, `"document"`, `"other"`
  - Normalizes MIME subtypes to human-friendly format names (e.g. `"quicktime"` → `"mov"`, `"svg+xml"` → `"svg"`)
  - Sanitizes EXIF data for JSON serialization (handles binaries, tuples, atoms)
  - Falls back when `:image` is not installed. No crash, just base metadata
- **`metadata` field on `Media` schema.** New `:map` field (default `%{}`) storing extracted metadata; persisted as a JSON column
- **New migration.** `add_metadata_to_media` migration adds the `metadata` column
- **Install task updated.** `mix phx_media_library.install` now generates migrations with `metadata`, `checksum`, and `checksum_algorithm` columns included from the start
- **Auto-extraction in pipeline.** `to_collection/3` extracts metadata after MIME detection and before storage
- `without_metadata/1` is a new builder function to skip extraction for a specific upload: `PhxMediaLibrary.without_metadata(adder)`
- **Global disable.** `config :phx_media_library, extract_metadata: false` disables extraction globally
- **Custom extractor.** `config :phx_media_library, metadata_extractor: MyApp.MetadataExtractor` to use your own implementation
- **Non-fatal extraction.** Extraction failures are logged as warnings but never block the upload; media is stored with an empty metadata map
- **Timestamp tracking.** Extracted metadata includes `"extracted_at"` ISO 8601 timestamp

#### 3b.3 Oban Conversion Queuing (Enhanced)

- `process_sync/2` is a new synchronous processing callback on `PhxMediaLibrary.AsyncProcessor.Oban` that delegates to `Conversions.process/2` for immediate conversions without queueing
- **Expanded documentation.** The Oban adapter now documents the full setup flow (deps, queue config, PhxMediaLibrary config), queue sizing guidance, and retry behaviour (max 3 attempts with exponential backoff)

### Changed

- **`MediaAdder` struct.** Added `:extract_metadata` field (default: `true` from `MetadataExtractor.enabled?/0`)
- `MediaAdder.to_collection/3` pipeline now includes a metadata extraction step between content-type verification and storage
- `store_and_persist/6` accepts a metadata map parameter and includes it in media attributes
- `resolve_source/1` now handles `{:url, url, opts}` three-element tuple for URL sources with options
- `source_type/1` handles `{:url, _, _}` pattern for URL sources with options
- **`Media` schema.** Added `metadata` field to `@optional_fields` in changeset

## [0.3.0] - 2026-02-27

### Added

- **Milestone 3a complete** (529 tests passing: 325 unit + 17 Oban worker + 28 new M3a + 159 integration)
- `PhxMediaLibrary.Error` is a base exception struct with `:message`, `:reason`, and `:metadata` fields. Used by `to_collection!/3` and other bang functions
- `PhxMediaLibrary.StorageError` is an exception for storage operation failures with `:operation`, `:path`, `:adapter`, and `:reason` fields. Auto-generates descriptive messages from context
- `PhxMediaLibrary.ValidationError` is an exception for pre-storage validation failures with `:field`, `:value`, and `:constraint` fields. Human-readable default messages for `:file_too_large`, `:invalid_mime_type`, and `:content_type_mismatch` reasons with automatic byte formatting (bytes/KB/MB)
- **Telemetry integration.** The `PhxMediaLibrary.Telemetry` module emits `:telemetry.span/3` events for all key operations:
  - `[:phx_media_library, :add, :start | :stop | :exception]`, media addition lifecycle
  - `[:phx_media_library, :delete, :start | :stop | :exception]`, media deletion lifecycle
  - `[:phx_media_library, :conversion, :start | :stop | :exception]`, image conversion processing
  - `[:phx_media_library, :storage, :start | :stop | :exception]`, storage adapter operations (put/get/delete/exists?)
  - `[:phx_media_library, :batch, :start | :stop | :exception]`, batch operations (clear, reorder)
  - `[:phx_media_library, :reorder]`, standalone event after successful reorder
  - All spans include `duration` in stop measurements and debug-level Logger output
- `Telemetry.event/3` is a standalone event emitter for one-shot notifications (e.g. `:media_reordered`)
- **`:max_size` collection option.** Maximum file size in bytes. Validated before storage (not after). Returns `{:error, {:file_too_large, actual_size, max_size}}`. `allow_media_upload/3` derives it into the LiveView upload's `:max_file_size`
- **`:verify_content_type` collection option.** When `true` (default), verifies that file content matches its declared MIME type. Set to `false` to skip verification for collections that accept arbitrary content
- `PhxMediaLibrary.MimeDetector` behaviour is pluggable content-based MIME type detection. Configurable via `:mime_detector` application env
- `PhxMediaLibrary.MimeDetector.Default` is a built-in magic-bytes detector supporting 50+ file formats:
  - Images: JPEG, PNG, GIF, WebP, BMP, TIFF, ICO, AVIF, HEIC/HEIF, SVG
  - Documents: PDF, RTF, Microsoft Office (legacy compound binary)
  - Audio: MP3 (ID3v2 + frame sync), OGG, FLAC, WAV, AIFF, AAC, MIDI, M4A
  - Video: MP4/M4V (ftyp brand detection for isom/iso2/mp41/mp42/dash/qt/3gp/3g2), AVI, MKV/WebM, FLV, QuickTime
  - Archives: ZIP, GZIP, BZIP2, 7-Zip, RAR, XZ, TAR (ustar at offset 257), Zstandard
  - Other: WASM, SQLite, ELF, Mach-O (32/64-bit, both endiannesses), PE (EXE/DLL), XML
- `MimeDetector.detect_with_fallback/2` detects from content, falls back to extension via `MIME.from_path/1`
- `MimeDetector.verify/3` compares detected content type against declared type. Returns `:ok` or `{:error, {:content_type_mismatch, detected, declared}}`
- **Content-based MIME detection in upload pipeline.** `MediaAdder` now reads file content once, detects MIME type from magic bytes (primary) with extension fallback, then validates against collection accepts. Catches executables disguised as images, etc.
- `PhxMediaLibrary.reorder/3` reorders media items by ID list: `PhxMediaLibrary.reorder(post, :images, [id3, id1, id2])`. Uses a single database transaction. It ignores IDs not in the collection. Emits `:batch` and `:reorder` Telemetry events
- `PhxMediaLibrary.move_to/2` moves a single media item to a specific 1-based position: `PhxMediaLibrary.move_to(media, 1)`. Clamps to collection size. Re-numbers all siblings in the collection
- **`:telemetry` dependency.** Added `{:telemetry, "~> 1.0"}` as a required dependency

### Changed

- **`clear_collection/2` now returns `{:ok, count}`.** Previously returned `:ok`. Now uses a single `delete_all` query instead of N+1 individual deletes. Files are still deleted from storage individually before the batch DB delete. Emits `[:phx_media_library, :batch]` Telemetry events
- **`clear_media/1` now returns `{:ok, count}`.** Same batch optimization and return type change as `clear_collection/2`
- **`to_collection!/3` raises `PhxMediaLibrary.Error`.** Previously raised `RuntimeError`. Now raises a structured `PhxMediaLibrary.Error` with `:reason` set to `:add_failed` and `:metadata` containing `:collection` and `:original_error`
- **MIME type detection is now content-based.** `MediaAdder` detects MIME from file content (magic bytes) as primary, falling back to extension. Previously relied solely on file extension via `MIME.from_path/1`
- **`StorageWrapper` emits Telemetry events.** All storage operations (put/get/delete/exists?) are now wrapped in `Telemetry.span/3`, which provides timing and operation metadata
- **`Conversions.process_conversion/5` emits Telemetry events.** Each individual conversion is wrapped in a `[:phx_media_library, :conversion]` span
- **`Media.delete/1` emits Telemetry events.** Wrapped in a `[:phx_media_library, :delete]` span
- **`MediaAdder.to_collection/3` emits Telemetry events.** Wrapped in a `[:phx_media_library, :add]` span with `:collection`, `:source_type`, and `:model` metadata
- **`allow_media_upload/3` derives `:max_file_size` from collection.** When a collection has `:max_size` configured, `allow_media_upload/3` passes it as `:max_file_size` to `Phoenix.LiveView.allow_upload/3`. Falls back to 10 MB default

### Fixed

- **`clear_collection/2` was N+1.** Fetched all media, then deleted one-by-one. Now deletes files from storage, then removes all DB records in a single `delete_all` query with `Ecto.Query.exclude(:order_by)` to satisfy Ecto's `delete_all` constraints
- **`clear_media/1` was N+1.** Same fix as `clear_collection/2`
- **`MediaAdder` read file content twice.** Previously `File.read!` happened in `store_and_persist` for both storage and checksum. Now reads once in `read_and_detect_mime/1` and threads the content through the pipeline

## [0.2.0] - 2026-02-27

### Added

- **Milestones 1 & 2 complete** (370 tests passing: 297 unit + 17 Oban worker + 56 integration)
- `PhxMediaLibrary.HasMedia` declarative DSL provides schema-level configuration via `media_collections do ... end` and `media_conversions do ... end` macro blocks as an alternative to the function-based approach. Both styles are supported and can be mixed. `convert/2` alias reads naturally in DSL context. Backed by `CollectionAccumulator` and `ConversionAccumulator` compile-time attribute accumulators, injected via `__before_compile__` with `defoverridable`
- **`has_media()` macro injects polymorphic `has_many`.** Calling `has_media()` inside a schema block now injects a real `has_many :media` association using `Ecto.Schema.__has_many__/4` directly (bypassing macro-expansion timing constraints). Uses `:where` for `mediable_type` scoping and `:defaults` for auto-populating on `build`. Collection-scoped variants via `has_media(:images)` add scoped associations (e.g. `has_many :images` filtered by both `mediable_type` and `collection_name`). Enables standard `Repo.preload(post, [:media, :images, :documents, :avatar])`
- `PhxMediaLibrary.media_query/2` is a composable `Ecto.Query` builder for a model's media, optionally filtered by collection. Supports further composition with `where/3`, `limit/2`, etc.
- `PhxMediaLibrary.verify_integrity/1` delegates to `Media.verify_integrity/1` to verify a stored file's checksum against the database record. Returns `:ok`, `{:error, :checksum_mismatch}`, or `{:error, :no_checksum}`
- `Media.compute_checksum/2` computes SHA-256, SHA-1, or MD5 checksums for binary content. Used during upload and integrity verification
- **Checksum fields on `Media` schema.** `checksum` (string) and `checksum_algorithm` (string, default `"sha256"`) fields. `MediaAdder.store_and_persist/4` computes SHA-256 before writing the file to storage. Migration `20240101000002_add_checksum_to_media.exs` adds columns and index
- `PhxMediaLibrary.ImageProcessor.Null` is a no-op image processor for when no image processing library is installed. All operations return `{:error, {:no_image_processor, message}}` with a message telling the developer to install `:image`
- **`Config.image_processor/0` auto-detection.** Defaults to `ImageProcessor.Image` when `:image` is available, falls back to `ImageProcessor.Null` otherwise
- **Polymorphic type derivation from Ecto table name.** `__media_type__/0` now defaults to `__schema__(:source)` (e.g. `"posts"`, `"blog_categories"`). Override via `use PhxMediaLibrary.HasMedia, media_type: "custom"` or by defining `def __media_type__, do: "custom"`. Replaces the broken naive pluralization (`"categorys"`)
- **Oban worker resolves full Conversion definitions.** `Workers.ProcessConversions` now stores `mediable_type` in job args, discovers the originating schema module via `find_model_module/1` (with `persistent_term` cache), retrieves full `Conversion` structs from the model's `get_media_conversions/1`, and filters by requested names. Handles legacy job args
- **`Config.disk_config/1` safe string-to-atom resolution.** No longer uses `String.to_existing_atom/1`, which crashes on unknown atoms. Now iterates configured disk keys and compares strings
- **`PathGenerator.full_path/2` uses `Code.ensure_loaded/1` + `function_exported?/3`.** Replaces fragile `Keyword.keys(__info__(:functions))` pattern for checking optional `path/2` callback
- **56 integration tests against real Postgres.** Full lifecycle tests in `test/phx_media_library/integration_test.exs` using `Ecto.Adapters.SQL.Sandbox`. Tagged with `@moduletag :db` and auto-excluded when Postgres is unavailable. Covers: add→store→retrieve→delete, collection MIME validation, single_file replacement, max_files enforcement, ordering, checksum integrity and tamper detection, polymorphic type scoping, `has_many` preloading, `media_query/2` composability, clear/delete operations, error paths, disk and memory storage adapters, concurrent access, JSON field round-trips, and unique UUID constraints
- **Test infrastructure.** `test_helper.exs` starts `TestRepo`, runs migrations programmatically, configures SQL Sandbox. `DataCase` module provides sandbox setup and `errors_on/1` helper. `NoOpProcessor` suppresses background task noise in integration tests
- `PhxMediaLibrary.Components` are ready-to-use Phoenix LiveView function components for media uploads and galleries
  - `<.media_upload>` is a drop-in upload zone with drag-and-drop, live image previews, progress bars, per-entry error display, and cancel buttons. Supports full-size and compact layouts, dark mode, and full slot/attr customization
  - `<.media_gallery>` is a stream-powered gallery grid for displaying existing media with delete-on-hover, image thumbnails, document type icons, configurable columns (2-6), and `:item`/`:empty` slots for custom rendering
  - `<.media_upload_button>` is a compact inline upload button for embedding within forms or tight layouts
  - Colocated `.MediaDropZone` JS hook for drag-and-drop visual feedback (drag enter/leave tracking, drop flash animation)
  - File type icon mapping (video, audio, PDF, spreadsheet, archive, etc.)
- `PhxMediaLibrary.LiveUpload` is a `use`-able helper module that imports upload lifecycle functions into any LiveView
  - `allow_media_upload/3` wraps `Phoenix.LiveView.allow_upload/3` with collection-aware defaults: auto-derives `:accept` from collection MIME types, `:max_entries` from `single_file`/`max_files`, and `:max_file_size` (default 10 MB)
  - `consume_media/5` wraps `consume_uploaded_entries/3` and persists each entry via `PhxMediaLibrary.add/2 |> to_collection/2`
  - `stream_existing_media/4` loads existing media for a model/collection into a LiveView stream with `"media-"` prefixed DOM IDs
  - `stream_media_items/3` inserts newly created media items into an existing stream
  - `delete_media_by_id/2` fetches and deletes a media record by ID (files + DB)
  - `media_upload_errors/1`, `media_entry_errors/2` translate Phoenix upload error atoms into human-readable strings
  - `has_upload_entries?/1`, `image_entry?/1` are introspection helpers for conditional UI rendering
  - `translate_upload_error/1` is extensible error translation with coverage of all built-in Phoenix upload errors
- **Media lifecycle event notifications.** `consume_media/5` and `delete_media_by_id/2` accept a `:notify` option (a pid). When set, sends `{:media_added, media_items}`, `{:media_error, reason}`, or `{:media_removed, media}` to the target process, so parent LiveViews can react via `handle_info/2`
- **17 Oban worker tests.** Dedicated test suite in `test/phx_media_library/workers/process_conversions_test.exs` using `Oban.Testing.perform_job/3`. Covers: missing media discard, full conversion resolution from model definitions (with dimensions/quality/fit), collection-scoped conversions, legacy job args fallback, unknown mediable_type fallback to name-only conversions, model module discovery and `persistent_term` caching, explicit model registry, and job changeset construction
- **`mix phx_media_library.regenerate` model module discovery.** The regenerate task now uses `ProcessConversions.find_model_module/1` to resolve the model module from `mediable_type`, so it can retrieve full conversion definitions instead of returning an empty list
- **Dialyzer ignore file.** `.dialyzer_ignore.exs` suppresses known false positives for `Mix.shell/0`, `Mix.Task.run/1`, and `Mix.Task` callback info across all mix tasks (`:mix` is not in the production PLT)

### Changed

- **`:image` dependency is now optional.** Marked `optional: true` in `mix.exs`. `ImageProcessor.Image` module is wrapped in `if Code.ensure_loaded?(Image)` and only compiled when `:image` is available. Library works for file storage without libvips installed
- **`max_files` collection cleanup now keeps newest items.** Previously `Enum.drop(max)` on ascending-ordered list incorrectly deleted the newest item. Now keeps the newest `max` items and deletes the oldest excess
- **`delete_media_by_id/1` → `delete_media_by_id/2`.** Now accepts an optional keyword list with `:notify` option. The 1-arity form still works (defaults to no notification)
- **`mix precommit` alias runs tests in correct environment.** Uses `cmd --cd . sh -c 'MIX_ENV=test mix test'` instead of bare `"test"`, which failed with an environment mismatch error
- **Credo --strict passes clean.** Refactored 13 functions across 9 files to resolve all nesting-depth and cyclomatic-complexity violations. Extracted helpers in `Config`, `Conversions`, `ResponsiveImages`, `ImageProcessor.Image`, `HasMedia.__before_compile__`, `Workers.ProcessConversions`, and all mix tasks. Replaced TODO tag with descriptive comment
- **Dialyzer passes clean.** Added `.dialyzer_ignore.exs` for known Mix PLT false positives. Fixed dead-code pattern in `mix phx_media_library.regenerate` (`get_model_module/1` now resolves modules instead of always returning `nil`)

### Fixed

- **`max_files` enforcement deleted wrong items.** `maybe_cleanup_collection` in `MediaAdder` used `Enum.drop(max)`, which removed the newest uploads instead of the oldest. Now uses `Enum.take(excess_count)` to delete the oldest excess items, keeping the `max` most recent
- **`Config.disk_config/1` crash on string disk names.** `String.to_existing_atom/1` crashed when the atom hadn't been referenced yet. Now iterates configured disk keys and matches by string comparison
- **`PathGenerator.full_path/2` fragile function check.** Replaced `Keyword.keys(__info__(:functions))` with `Code.ensure_loaded/1` + `function_exported?/3` for optional callback detection
- **Polymorphic type derivation was naive.** `get_mediable_type/1` appended "s" to module name (producing `"categorys"` for `Category`). Now derives from Ecto table name (`__schema__(:source)`) with configurable overrides
- **Oban worker created empty Conversion structs.** Worker only serialized conversion names, losing dimensions/quality/format. Now stores `mediable_type` in job args, discovers the model module, and retrieves full `Conversion` definitions
- **`has_media()` macro was a no-op.** Did not inject any Ecto association. Now injects a polymorphic `has_many` via `Ecto.Schema.__has_many__/4` with `:where` and `:defaults` for proper scoping
- **Credo alias ordering.** Fixed alphabetical ordering of alias groups in `PathGenerator`, `UrlGenerator`, `AsyncProcessor`, `ResponsiveImages`, `Components`, `Fixtures`, and `PathGeneratorTest`
- **`ImageProcessor.Image.save/3` simplified.** Extracted `write_opts_for_format/2` to eliminate nested `case` inside `save/3`, reducing cyclomatic complexity
- **`ImageProcessor.Image.maybe_resize/2` flattened.** Replaced nested `case` on fit mode with multiple function clauses for `:crop`, `:contain`/`:cover`/`:fill`, and default
- **`Config.disk_config/1` simplified.** Extracted `resolve_disk_key/2` and `lookup_disk/2` to reduce cyclomatic complexity from 11 to under 9
- **`HasMedia.__before_compile__/1` decomposed.** Extracted `build_media_type_def/2`, `build_helpers/0`, and `build_dsl_defs/4` private functions to reduce nesting depth
- **`Workers.ProcessConversions.resolve_conversions/3` flattened.** Extracted `get_model_conversions/2` helper to eliminate nested `if`/`function_exported?` checks
- **Mix task refactoring.** `clean.ex`: extracted `report_orphaned_files/3`, `delete_or_report_file/3`, `find_orphaned_records/2`, `report_orphaned_records/3`, `delete_or_report_record/3`. `regenerate.ex`: extracted `conversions_for_media/2`, `run_or_report/4`, `do_regenerate/4`; used `Enum.map_join/3` instead of `Enum.map/2 |> Enum.join/2`. `regenerate_responsive.ex`: extracted `build_responsive_query/2`, `process_item/4`, `update_responsive_images/3`
- **`ResponsiveImages.generate/2` decomposed.** Extracted `generate_variants/7`, `build_responsive_data/7`, `maybe_generate_placeholder/2` to reduce nesting depth. Extracted `generate_conversion_data/1` and `generate_single_conversion_data/2` from `generate_all/1`

## [0.1.1] - 2026-02-24

### Fixed

- Fixed `Image.write/2` return value handling. Now handles the `{:ok, image}` tuple
- Fixed `Image.thumbnail/2` syntax to use proper keyword list options
- Fixed responsive images generation to handle the Image library API
- Fixed conversions processor to destructure Image operation results
- Fixed path generator to handle conversion paths with proper defaults

## [0.1.0] - 2026-02-24

### Added

- Initial release of PhxMediaLibrary
- **Core functionality**
  - Associate media files with any Ecto schema via polymorphic associations
  - Fluent API for adding media (`add/2`, `add_from_url/2`, `to_collection/3`)
  - Custom filename support with `using_filename/2`
  - Custom properties/metadata with `with_custom_properties/2`
- **Collections**
  - Organize media into named collections
  - MIME type validation with `:accepts` option
  - Single file collections with `:single_file` option
  - Maximum file limits with `:max_files` option
  - Per-collection storage disk configuration
  - Fallback URLs for empty collections
- **Image conversions**
  - Automatic thumbnail and preview generation
  - Configurable width, height, quality, and format
  - Multiple fit modes: `:contain`, `:cover`, `:fill`, `:crop`
  - Collection-specific conversions
- **Responsive images**
  - Automatic srcset generation at configurable widths
  - Tiny placeholder generation for progressive loading
  - `with_responsive_images/1` to enable per-media
- **Storage backends**
  - `PhxMediaLibrary.Storage.Disk`, local filesystem storage
  - `PhxMediaLibrary.Storage.S3`, Amazon S3 and compatible services
  - `PhxMediaLibrary.Storage.Memory`, in-memory storage for testing
  - `PhxMediaLibrary.Storage` behaviour for custom adapters
- **Async processing**
  - `PhxMediaLibrary.AsyncProcessor.Task`, simple Task-based processing
  - `PhxMediaLibrary.AsyncProcessor.Oban`, Oban-based job processing
  - `PhxMediaLibrary.AsyncProcessor` behaviour for custom processors
- **Phoenix view helpers**
  - `<.media_img>`, simple image rendering
  - `<.responsive_img>`, responsive image with srcset and placeholder
  - `<.picture>`, picture element for art direction
- **Mix tasks**
  - `mix phx_media_library.install` generates a migration and prints setup instructions
  - `mix phx_media_library.regenerate` regenerates conversions for existing media
  - `mix phx_media_library.regenerate_responsive` regenerates responsive images
  - `mix phx_media_library.clean` finds and removes orphaned files
  - `mix phx_media_library.gen.migration` generates custom migrations

[Unreleased]: https://github.com/mike-kostov/phx_media_library/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/mike-kostov/phx_media_library/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mike-kostov/phx_media_library/releases/tag/v0.1.0