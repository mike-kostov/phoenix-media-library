# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-02-27

### Added

- **Milestone 3c complete** (717 tests passing: up from 653 in v0.4.0)

#### 3.5 — Soft Deletes

- **Opt-in soft deletes** — `config :phx_media_library, soft_deletes: true` enables soft deletes globally. Disabled by default — no behaviour change for existing users
- **`delete/1` respects config** — When soft deletes are enabled, `delete/1` sets `deleted_at` instead of removing the record and files. When disabled, behaviour is unchanged (hard delete)
- **`permanently_delete/1`** — Always performs a hard delete (removes files from storage and database record) regardless of the soft deletes configuration
- **`soft_delete/1`** — Explicitly soft-delete a media item by setting its `deleted_at` timestamp. Files are preserved in storage until `permanently_delete/1` or `purge_trashed/2` is called
- **`restore/1`** — Restore a soft-deleted media item by clearing `deleted_at`
- **`trashed?/1`** — Predicate to check whether a media item has been soft-deleted
- **`get_trashed_media/2`** — Query only soft-deleted media for a model, optionally filtered by collection (inverse of `get_media/2`)
- **`purge_trashed/2`** — Permanently delete all trashed media for a model, with optional `:before` cutoff for age-based cleanup (e.g. `before: DateTime.add(DateTime.utc_now(), -30, :day)`)
- **Query scoping** — `get_media/2`, `get_first_media/2`, `media_query/2`, and `Media.for_model/2` automatically exclude soft-deleted records when soft deletes are enabled
- **`exclude_trashed/1`** and **`only_trashed/1`** — Query helpers on `Media` for composing custom Ecto queries
- **`clear_collection/2` and `clear_media/1` respect soft deletes** — When enabled, these set `deleted_at` via `update_all` instead of deleting records. Files are preserved until purge
- **`mix phx_media_library.purge_deleted`** — Mix task to permanently remove old soft-deleted media. Options: `--days N` (default: 30), `--all`, `--dry-run`, `--yes`
- **New migration** — `add_deleted_at_to_media` adds `deleted_at` column with index
- **Install task updated** — `mix phx_media_library.install` now includes `deleted_at` column and index from the start

#### 3.6 — Streaming Upload Support

- **File streaming** — `MediaAdder` no longer loads entire files into memory via `File.read!`. Files are streamed to storage in 64 KB chunks using `File.stream!/2`
- **Single-pass checksum** — SHA-256 checksum is computed during the stream (via `Stream.map/2` feeding `:crypto.hash_update/2`) instead of a separate full-file read
- **Header-only MIME detection** — Only the first 512 bytes are read for magic-byte MIME type detection, sufficient for all supported formats (including TAR at offset 257)
- **Known issue resolved** — "MediaAdder loads entire file into memory" is no longer applicable

#### 3.7 — Direct S3 Upload (Presigned URLs)

- **`presigned_upload_url/3`** — Generate a presigned URL for direct client-to-S3 uploads. Returns `{:ok, url, fields, upload_key}`. Requires `:filename` option; supports `:content_type`, `:expires_in`, `:max_size`
- **`complete_external_upload/4`** — Create a `Media` database record after the client uploads directly to storage. Requires `:filename`, `:content_type`, `:size`; supports `:custom_properties`, `:checksum`, `:checksum_algorithm`
- **`presigned_upload_url/3` callback** — New optional callback on `PhxMediaLibrary.Storage` behaviour. S3 adapter implements it; Disk and Memory adapters return `{:error, :not_supported}`
- **`StorageWrapper.presigned_upload_url/3`** — Adapter-aware wrapper that checks `function_exported?/3` and returns `{:error, :not_supported}` for adapters without the callback
- **Telemetry** — `complete_external_upload/4` emits `[:phx_media_library, :add, :start | :stop]` events with `source_type: :external`

### Changed

- **`MediaAdder.store_and_persist/6` → `store_and_persist/5`** — No longer receives `file_content` as a parameter. Checksum is computed during streaming
- **`MediaAdder.read_and_detect_mime/1`** — Now reads only the first 512 bytes (header) instead of the entire file. Returns `{:ok, file_info, header}` instead of `{:ok, file_info, file_content}`
- **`Media.delete/1` return type** — Returns `{:ok, media}` when soft deletes are enabled (soft delete), or `:ok` when disabled (hard delete)
- **`Media` schema** — Added `deleted_at` field (`:utc_datetime`, default `nil`)
- **`Media.permanently_delete/1`** — Renamed from the previous `delete/1` hard-delete implementation. `delete/1` now dispatches based on soft deletes config
- **`PhxMediaLibrary.Storage` behaviour** — Added optional `presigned_upload_url/3` callback
- **Install task migration template** — Now includes `deleted_at` column and index

## [0.4.0] - 2026-02-27

### Added

- **Milestone 3b complete** (653 tests passing: up from 529 in v0.3.0)

#### 3b.1 — Remote URL Sources (Enhanced)

- **URL validation** — `add_from_url/3` now validates URL scheme (only `http`/`https` allowed), rejects missing hosts, and returns descriptive `{:error, {:invalid_url, reason}}` tuples for `ftp://`, `file://`, or malformed URLs
- **Custom request headers** — `add_from_url/3` accepts `:headers` option for authenticated downloads (e.g. `headers: [{"Authorization", "Bearer token"}]`)
- **Download timeout** — `:timeout` option sets a receive timeout for slow servers
- **Download telemetry** — New `[:phx_media_library, :download, :start | :stop | :exception]` events with URL, size, and MIME type metadata
- **Source URL tracking** — When media is added from a URL, the original URL is automatically stored in `custom_properties["source_url"]`
- **Broader success codes** — Downloads now accept any 2xx status code (200–299), not just 200

#### 3b.2 — Automatic Metadata Extraction

- **`PhxMediaLibrary.MetadataExtractor`** — New behaviour for extracting file metadata with `extract/3` callback
- **`PhxMediaLibrary.MetadataExtractor.Default`** — Default implementation that:
  - Extracts image dimensions (`width`, `height`), alpha channel presence, and EXIF data via the `:image` library (when available)
  - Classifies files into type categories: `"image"`, `"video"`, `"audio"`, `"document"`, `"other"`
  - Normalizes MIME subtypes to human-friendly format names (e.g. `"quicktime"` → `"mov"`, `"svg+xml"` → `"svg"`)
  - Sanitizes EXIF data for JSON serialization (handles binaries, tuples, atoms)
  - Gracefully falls back when `:image` is not installed — no crash, just base metadata
- **`metadata` field on `Media` schema** — New `:map` field (default `%{}`) storing extracted metadata; persisted as a JSON column
- **New migration** — `add_metadata_to_media` migration adds the `metadata` column
- **Install task updated** — `mix phx_media_library.install` now generates migrations with `metadata`, `checksum`, and `checksum_algorithm` columns included from the start
- **Auto-extraction in pipeline** — `to_collection/3` automatically extracts metadata after MIME detection and before storage
- **`without_metadata/1`** — New builder function to skip extraction for a specific upload: `PhxMediaLibrary.without_metadata(adder)`
- **Global disable** — `config :phx_media_library, extract_metadata: false` disables extraction globally
- **Custom extractor** — `config :phx_media_library, metadata_extractor: MyApp.MetadataExtractor` to use your own implementation
- **Non-fatal extraction** — Extraction failures are logged as warnings but never block the upload; media is stored with an empty metadata map
- **Timestamp tracking** — Extracted metadata includes `"extracted_at"` ISO 8601 timestamp

#### 3b.3 — Oban Conversion Queuing (Enhanced)

- **`process_sync/2`** — Added synchronous processing callback to `PhxMediaLibrary.AsyncProcessor.Oban`, delegating to `Conversions.process/2` for immediate conversions without queueing
- **Enhanced documentation** — Oban adapter now documents full setup flow (deps, queue config, PhxMediaLibrary config), queue sizing guidance, and retry behaviour (max 3 attempts with exponential backoff)

### Changed

- **`MediaAdder` struct** — Added `:extract_metadata` field (default: `true` from `MetadataExtractor.enabled?/0`)
- **`MediaAdder.to_collection/3`** — Pipeline now includes metadata extraction step between content-type verification and storage
- **`store_and_persist/6`** — Accepts metadata map parameter and includes it in media attributes
- **`resolve_source/1`** — Now handles `{:url, url, opts}` three-element tuple for URL sources with options
- **`source_type/1`** — Handles `{:url, _, _}` pattern for URL sources with options
- **`Media` schema** — Added `metadata` field to `@optional_fields` in changeset

## [0.3.0] - 2026-02-27

### Added

- **Milestone 3a complete** (529 tests passing: 325 unit + 17 Oban worker + 28 new M3a + 159 integration)
- **`PhxMediaLibrary.Error`** — Base exception struct with `:message`, `:reason`, and `:metadata` fields. Used by `to_collection!/3` and other bang functions
- **`PhxMediaLibrary.StorageError`** — Exception for storage operation failures with `:operation`, `:path`, `:adapter`, and `:reason` fields. Auto-generates descriptive messages from context
- **`PhxMediaLibrary.ValidationError`** — Exception for pre-storage validation failures with `:field`, `:value`, and `:constraint` fields. Human-readable default messages for `:file_too_large`, `:invalid_mime_type`, and `:content_type_mismatch` reasons with automatic byte formatting (bytes/KB/MB)
- **Telemetry integration** — `PhxMediaLibrary.Telemetry` module emitting `:telemetry.span/3` events for all key operations:
  - `[:phx_media_library, :add, :start | :stop | :exception]` — media addition lifecycle
  - `[:phx_media_library, :delete, :start | :stop | :exception]` — media deletion lifecycle
  - `[:phx_media_library, :conversion, :start | :stop | :exception]` — image conversion processing
  - `[:phx_media_library, :storage, :start | :stop | :exception]` — storage adapter operations (put/get/delete/exists?)
  - `[:phx_media_library, :batch, :start | :stop | :exception]` — batch operations (clear, reorder)
  - `[:phx_media_library, :reorder]` — standalone event after successful reorder
  - All spans include `duration` in stop measurements and debug-level Logger output
- **`Telemetry.event/3`** — Standalone event emitter for one-shot notifications (e.g. `:media_reordered`)
- **`:max_size` collection option** — Maximum file size in bytes. Validated before storage (not after). Returns `{:error, {:file_too_large, actual_size, max_size}}`. Automatically derived into LiveView upload's `:max_file_size` via `allow_media_upload/3`
- **`:verify_content_type` collection option** — When `true` (default), verifies that file content matches its declared MIME type. Set to `false` to skip verification for collections that accept arbitrary content
- **`PhxMediaLibrary.MimeDetector` behaviour** — Pluggable content-based MIME type detection. Configurable via `:mime_detector` application env
- **`PhxMediaLibrary.MimeDetector.Default`** — Built-in magic-bytes detector supporting 50+ file formats:
  - Images: JPEG, PNG, GIF, WebP, BMP, TIFF, ICO, AVIF, HEIC/HEIF, SVG
  - Documents: PDF, RTF, Microsoft Office (legacy compound binary)
  - Audio: MP3 (ID3v2 + frame sync), OGG, FLAC, WAV, AIFF, AAC, MIDI, M4A
  - Video: MP4/M4V (ftyp brand detection for isom/iso2/mp41/mp42/dash/qt/3gp/3g2), AVI, MKV/WebM, FLV, QuickTime
  - Archives: ZIP, GZIP, BZIP2, 7-Zip, RAR, XZ, TAR (ustar at offset 257), Zstandard
  - Other: WASM, SQLite, ELF, Mach-O (32/64-bit, both endiannesses), PE (EXE/DLL), XML
- **`MimeDetector.detect_with_fallback/2`** — Detects from content, falls back to extension via `MIME.from_path/1`
- **`MimeDetector.verify/3`** — Compares detected content type against declared type. Returns `:ok` or `{:error, {:content_type_mismatch, detected, declared}}`
- **Content-based MIME detection in upload pipeline** — `MediaAdder` now reads file content once, detects MIME type from magic bytes (primary) with extension fallback, then validates against collection accepts. Catches executables disguised as images, etc.
- **`PhxMediaLibrary.reorder/3`** — Reorder media items by ID list: `PhxMediaLibrary.reorder(post, :images, [id3, id1, id2])`. Uses a single database transaction. IDs not in the collection are silently ignored. Emits `:batch` and `:reorder` Telemetry events
- **`PhxMediaLibrary.move_to/2`** — Move a single media item to a specific 1-based position: `PhxMediaLibrary.move_to(media, 1)`. Clamps to collection size. Re-numbers all siblings in the collection
- **`:telemetry` dependency** — Added `{:telemetry, "~> 1.0"}` as a required dependency

### Changed

- **`clear_collection/2` now returns `{:ok, count}`** — Previously returned `:ok`. Now uses a single `delete_all` query instead of N+1 individual deletes. Files are still deleted from storage individually before the batch DB delete. Emits `[:phx_media_library, :batch]` Telemetry events
- **`clear_media/1` now returns `{:ok, count}`** — Same batch optimization and return type change as `clear_collection/2`
- **`to_collection!/3` raises `PhxMediaLibrary.Error`** — Previously raised `RuntimeError`. Now raises a structured `PhxMediaLibrary.Error` with `:reason` set to `:add_failed` and `:metadata` containing `:collection` and `:original_error`
- **MIME type detection is now content-based** — `MediaAdder` detects MIME from file content (magic bytes) as primary, falling back to extension. Previously relied solely on file extension via `MIME.from_path/1`
- **`StorageWrapper` emits Telemetry events** — All storage operations (put/get/delete/exists?) are now wrapped in `Telemetry.span/3`, providing timing and operation metadata
- **`Conversions.process_conversion/5` emits Telemetry events** — Each individual conversion is wrapped in a `[:phx_media_library, :conversion]` span
- **`Media.delete/1` emits Telemetry events** — Wrapped in a `[:phx_media_library, :delete]` span
- **`MediaAdder.to_collection/3` emits Telemetry events** — Wrapped in a `[:phx_media_library, :add]` span with `:collection`, `:source_type`, and `:model` metadata
- **`allow_media_upload/3` derives `:max_file_size` from collection** — When a collection has `:max_size` configured, it's automatically passed as `:max_file_size` to `Phoenix.LiveView.allow_upload/3`. Falls back to 10 MB default

### Fixed

- **`clear_collection/2` was N+1** — Fetched all media, then deleted one-by-one. Now deletes files from storage, then removes all DB records in a single `delete_all` query with `Ecto.Query.exclude(:order_by)` to satisfy Ecto's `delete_all` constraints
- **`clear_media/1` was N+1** — Same fix as `clear_collection/2`
- **`MediaAdder` read file content twice** — Previously `File.read!` happened in `store_and_persist` for both storage and checksum. Now reads once in `read_and_detect_mime/1` and threads the content through the pipeline

## [0.2.0] - 2026-02-27

### Added

- **Milestones 1 & 2 complete** (370 tests passing: 297 unit + 17 Oban worker + 56 integration)
- **`PhxMediaLibrary.HasMedia` declarative DSL** — Schema-level configuration via `media_collections do ... end` and `media_conversions do ... end` macro blocks as an alternative to the function-based approach. Both styles are supported and can be mixed. `convert/2` alias reads naturally in DSL context. Backed by `CollectionAccumulator` and `ConversionAccumulator` compile-time attribute accumulators, injected via `__before_compile__` with `defoverridable`
- **`has_media()` macro injects polymorphic `has_many`** — Calling `has_media()` inside a schema block now injects a real `has_many :media` association using `Ecto.Schema.__has_many__/4` directly (bypassing macro-expansion timing constraints). Uses `:where` for `mediable_type` scoping and `:defaults` for auto-populating on `build`. Collection-scoped variants via `has_media(:images)` add scoped associations (e.g. `has_many :images` filtered by both `mediable_type` and `collection_name`). Enables standard `Repo.preload(post, [:media, :images, :documents, :avatar])`
- **`PhxMediaLibrary.media_query/2`** — Composable `Ecto.Query` builder for a model's media, optionally filtered by collection. Supports further composition with `where/3`, `limit/2`, etc.
- **`PhxMediaLibrary.verify_integrity/1`** — Delegates to `Media.verify_integrity/1` to verify a stored file's checksum against the database record. Returns `:ok`, `{:error, :checksum_mismatch}`, or `{:error, :no_checksum}`
- **`Media.compute_checksum/2`** — Computes SHA-256, SHA-1, or MD5 checksums for binary content. Used during upload and integrity verification
- **Checksum fields on `Media` schema** — `checksum` (string) and `checksum_algorithm` (string, default `"sha256"`) fields. SHA-256 computed automatically during `MediaAdder.store_and_persist/4` before file is written to storage. Migration `20240101000002_add_checksum_to_media.exs` adds columns and index
- **`PhxMediaLibrary.ImageProcessor.Null`** — No-op image processor for when no image processing library is installed. All operations return `{:error, {:no_image_processor, message}}` with a clear message guiding the developer to install `:image`
- **`Config.image_processor/0` auto-detection** — Defaults to `ImageProcessor.Image` when `:image` is available, falls back to `ImageProcessor.Null` otherwise
- **Polymorphic type derivation from Ecto table name** — `__media_type__/0` now defaults to `__schema__(:source)` (e.g. `"posts"`, `"blog_categories"`). Override via `use PhxMediaLibrary.HasMedia, media_type: "custom"` or by defining `def __media_type__, do: "custom"`. Replaces the broken naive pluralization (`"categorys"`)
- **Oban worker resolves full Conversion definitions** — `Workers.ProcessConversions` now stores `mediable_type` in job args, discovers the originating schema module via `find_model_module/1` (with `persistent_term` cache), retrieves full `Conversion` structs from the model's `get_media_conversions/1`, and filters by requested names. Handles legacy job args gracefully
- **`Config.disk_config/1` safe string-to-atom resolution** — No longer uses `String.to_existing_atom/1` which crashes on unknown atoms. Now iterates configured disk keys and compares strings
- **`PathGenerator.full_path/2` uses `Code.ensure_loaded/1` + `function_exported?/3`** — Replaces fragile `Keyword.keys(__info__(:functions))` pattern for checking optional `path/2` callback
- **56 integration tests against real Postgres** — Full lifecycle tests in `test/phx_media_library/integration_test.exs` using `Ecto.Adapters.SQL.Sandbox`. Tagged with `@moduletag :db` and auto-excluded when Postgres is unavailable. Covers: add→store→retrieve→delete, collection MIME validation, single_file replacement, max_files enforcement, ordering, checksum integrity and tamper detection, polymorphic type scoping, `has_many` preloading, `media_query/2` composability, clear/delete operations, error paths, disk and memory storage adapters, concurrent access, JSON field round-trips, and unique UUID constraints
- **Test infrastructure** — `test_helper.exs` starts `TestRepo`, runs migrations programmatically, configures SQL Sandbox. `DataCase` module provides sandbox setup and `errors_on/1` helper. `NoOpProcessor` suppresses background task noise in integration tests
- **`PhxMediaLibrary.Components`** — Ready-to-use Phoenix LiveView function components for media uploads and galleries
  - `<.media_upload>` — Drop-in upload zone with drag-and-drop, live image previews, progress bars, per-entry error display, and cancel buttons. Supports full-size and compact layouts, dark mode, and full slot/attr customization
  - `<.media_gallery>` — Stream-powered gallery grid for displaying existing media with delete-on-hover, image thumbnails, document type icons, configurable columns (2–6), and `:item`/`:empty` slots for custom rendering
  - `<.media_upload_button>` — Compact inline upload button for embedding within forms or tight layouts
  - Colocated `.MediaDropZone` JS hook for enhanced drag-and-drop visual feedback (drag enter/leave tracking, drop flash animation)
  - File type icon mapping (video, audio, PDF, spreadsheet, archive, etc.)
- **`PhxMediaLibrary.LiveUpload`** — `use`-able helper module that imports upload lifecycle functions into any LiveView
  - `allow_media_upload/3` — Wraps `Phoenix.LiveView.allow_upload/3` with collection-aware defaults: auto-derives `:accept` from collection MIME types, `:max_entries` from `single_file`/`max_files`, and `:max_file_size` (default 10 MB)
  - `consume_media/5` — Wraps `consume_uploaded_entries/3` and persists each entry via `PhxMediaLibrary.add/2 |> to_collection/2`
  - `stream_existing_media/4` — Loads existing media for a model/collection into a LiveView stream with `"media-"` prefixed DOM IDs
  - `stream_media_items/3` — Inserts newly created media items into an existing stream
  - `delete_media_by_id/2` — Fetches and deletes a media record by ID (files + DB)
  - `media_upload_errors/1`, `media_entry_errors/2` — Translates Phoenix upload error atoms into human-readable strings
  - `has_upload_entries?/1`, `image_entry?/1` — Introspection helpers for conditional UI rendering
  - `translate_upload_error/1` — Extensible error translation with coverage of all built-in Phoenix upload errors
- **Media lifecycle event notifications** — `consume_media/5` and `delete_media_by_id/2` accept a `:notify` option (a pid). When set, sends `{:media_added, media_items}`, `{:media_error, reason}`, or `{:media_removed, media}` to the target process, enabling parent LiveViews to react via `handle_info/2`
- **17 Oban worker tests** — Dedicated test suite in `test/phx_media_library/workers/process_conversions_test.exs` using `Oban.Testing.perform_job/3`. Covers: missing media discard, full conversion resolution from model definitions (with dimensions/quality/fit), collection-scoped conversions, legacy job args fallback, unknown mediable_type fallback to name-only conversions, model module discovery and `persistent_term` caching, explicit model registry, and job changeset construction
- **`mix phx_media_library.regenerate` model module discovery** — The regenerate task now uses `ProcessConversions.find_model_module/1` to resolve the model module from `mediable_type`, enabling it to retrieve full conversion definitions instead of returning an empty list
- **Dialyzer ignore file** — `.dialyzer_ignore.exs` suppresses known false positives for `Mix.shell/0`, `Mix.Task.run/1`, and `Mix.Task` callback info across all mix tasks (`:mix` is not in the production PLT)

### Changed

- **`:image` dependency is now optional** — Marked `optional: true` in `mix.exs`. `ImageProcessor.Image` module is wrapped in `if Code.ensure_loaded?(Image)` and only compiled when `:image` is available. Library works for file storage without libvips installed
- **`max_files` collection cleanup now keeps newest items** — Previously `Enum.drop(max)` on ascending-ordered list incorrectly deleted the newest item. Now correctly keeps the newest `max` items and deletes the oldest excess
- **`delete_media_by_id/1` → `delete_media_by_id/2`** — Now accepts an optional keyword list with `:notify` option. The 1-arity form still works (defaults to no notification)
- **`mix precommit` alias runs tests in correct environment** — Uses `cmd --cd . sh -c 'MIX_ENV=test mix test'` instead of bare `"test"` which failed with an environment mismatch error
- **Credo --strict passes clean** — Refactored 13 functions across 9 files to resolve all nesting-depth and cyclomatic-complexity violations. Extracted helpers in `Config`, `Conversions`, `ResponsiveImages`, `ImageProcessor.Image`, `HasMedia.__before_compile__`, `Workers.ProcessConversions`, and all mix tasks. Replaced TODO tag with descriptive comment
- **Dialyzer passes clean** — Added `.dialyzer_ignore.exs` for known Mix PLT false positives. Fixed dead-code pattern in `mix phx_media_library.regenerate` (`get_model_module/1` now resolves modules instead of always returning `nil`)

### Fixed

- **`max_files` enforcement deleted wrong items** — `maybe_cleanup_collection` in `MediaAdder` used `Enum.drop(max)` which removed the newest uploads instead of the oldest. Now uses `Enum.take(excess_count)` to delete the oldest excess items, keeping the `max` most recent
- **`Config.disk_config/1` crash on string disk names** — `String.to_existing_atom/1` crashed when the atom hadn't been referenced yet. Now iterates configured disk keys and matches by string comparison
- **`PathGenerator.full_path/2` fragile function check** — Replaced `Keyword.keys(__info__(:functions))` with `Code.ensure_loaded/1` + `function_exported?/3` for robust optional callback detection
- **Polymorphic type derivation was naive** — `get_mediable_type/1` appended "s" to module name (producing `"categorys"` for `Category`). Now derives from Ecto table name (`__schema__(:source)`) with configurable overrides
- **Oban worker created empty Conversion structs** — Worker only serialized conversion names, losing dimensions/quality/format. Now stores `mediable_type` in job args, discovers the model module, and retrieves full `Conversion` definitions
- **`has_media()` macro was a no-op** — Did not inject any Ecto association. Now injects a polymorphic `has_many` via `Ecto.Schema.__has_many__/4` with `:where` and `:defaults` for proper scoping
- **Credo alias ordering** — Fixed alphabetical ordering of alias groups in `PathGenerator`, `UrlGenerator`, `AsyncProcessor`, `ResponsiveImages`, `Components`, `Fixtures`, and `PathGeneratorTest`
- **`ImageProcessor.Image.save/3` simplified** — Extracted `write_opts_for_format/2` to eliminate nested `case` inside `save/3`, reducing cyclomatic complexity
- **`ImageProcessor.Image.maybe_resize/2` flattened** — Replaced nested `case` on fit mode with multiple function clauses for `:crop`, `:contain`/`:cover`/`:fill`, and default
- **`Config.disk_config/1` simplified** — Extracted `resolve_disk_key/2` and `lookup_disk/2` to reduce cyclomatic complexity from 11 to under 9
- **`HasMedia.__before_compile__/1` decomposed** — Extracted `build_media_type_def/2`, `build_helpers/0`, and `build_dsl_defs/4` private functions to reduce nesting depth
- **`Workers.ProcessConversions.resolve_conversions/3` flattened** — Extracted `get_model_conversions/2` helper to eliminate nested `if`/`function_exported?` checks
- **Mix task refactoring** — `clean.ex`: extracted `report_orphaned_files/3`, `delete_or_report_file/3`, `find_orphaned_records/2`, `report_orphaned_records/3`, `delete_or_report_record/3`. `regenerate.ex`: extracted `conversions_for_media/2`, `run_or_report/4`, `do_regenerate/4`; used `Enum.map_join/3` instead of `Enum.map/2 |> Enum.join/2`. `regenerate_responsive.ex`: extracted `build_responsive_query/2`, `process_item/4`, `update_responsive_images/3`
- **`ResponsiveImages.generate/2` decomposed** — Extracted `generate_variants/7`, `build_responsive_data/7`, `maybe_generate_placeholder/2` to reduce nesting depth. Extracted `generate_conversion_data/1` and `generate_single_conversion_data/2` from `generate_all/1`

## [0.1.1] - 2026-02-24

### Fixed

- Fixed `Image.write/2` return value handling - now correctly handles `{:ok, image}` tuple
- Fixed `Image.thumbnail/2` syntax to use proper keyword list options
- Fixed responsive images generation to handle Image library API correctly
- Fixed conversions processor to properly destructure Image operation results
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
  - `PhxMediaLibrary.Storage.Disk` - Local filesystem storage
  - `PhxMediaLibrary.Storage.S3` - Amazon S3 and compatible services
  - `PhxMediaLibrary.Storage.Memory` - In-memory storage for testing
  - `PhxMediaLibrary.Storage` behaviour for custom adapters
- **Async processing**
  - `PhxMediaLibrary.AsyncProcessor.Task` - Simple Task-based processing
  - `PhxMediaLibrary.AsyncProcessor.Oban` - Oban-based job processing
  - `PhxMediaLibrary.AsyncProcessor` behaviour for custom processors
- **Phoenix view helpers**
  - `<.media_img>` - Simple image rendering
  - `<.responsive_img>` - Responsive image with srcset and placeholder
  - `<.picture>` - Picture element for art direction
- **Mix tasks**
  - `mix phx_media_library.install` - Generate migration and print setup instructions
  - `mix phx_media_library.regenerate` - Regenerate conversions for existing media
  - `mix phx_media_library.regenerate_responsive` - Regenerate responsive images
  - `mix phx_media_library.clean` - Find and remove orphaned files
  - `mix phx_media_library.gen.migration` - Generate custom migrations

[Unreleased]: https://github.com/mike-kostov/phx_media_library/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/mike-kostov/phx_media_library/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mike-kostov/phx_media_library/releases/tag/v0.1.0