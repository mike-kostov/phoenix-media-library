# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mike-kostov/phx_media_library/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mike-kostov/phx_media_library/releases/tag/v0.1.0