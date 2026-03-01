# PhxMediaLibrary — Priorities & Roadmap

This document tracks the priorities for developing PhxMediaLibrary. It is ordered by what matters most: **Developer Experience first**.

The guiding principle: *every feature should reduce repetitive work for the developer using this library.*

---

## Table of Contents

- [Vision](#vision)
- [Milestone 1 — Killer DX: LiveView Media Component (v0.5.1) ✅](#milestone-1--killer-dx-liveview-media-component-v051-)
- [Milestone 2 — Make the Core Solid ✅](#milestone-2--make-the-core-solid-)
- [Milestone 3a — Error Handling & Validation Hardening (v0.3.0) ✅](#milestone-3a--error-handling--validation-hardening-v030-)
- [Milestone 3b — Remote URLs, Metadata & Oban Enhancements (v0.4.0) ✅](#milestone-3b--remote-urls-metadata--oban-enhancements-v040-)
- [Milestone 3c — Production Hardening (v0.5.0) ✅](#milestone-3c--production-hardening-v050-)
- [Milestone 4 — Best-in-Class](#milestone-4--best-in-class)
- [Design Decisions](#design-decisions)
- [Known Issues](#known-issues)
- [Parking Lot](#parking-lot)

---

## Vision

PhxMediaLibrary should be the **obvious choice** when an Elixir/Phoenix developer needs to associate files with database records. The bar is Spatie's Laravel Media Library — but adapted for how Elixir and Phoenix actually work.

A developer should be able to go from zero to a working media upload UI in **under 5 minutes**:

1. `mix phx_media_library.install`
2. Add `use PhxMediaLibrary.HasMedia` to a schema
3. Drop `<.media_upload>` into a LiveView
4. Done.

Everything else — conversions, responsive images, S3 storage — should layer on top without rewriting anything.

---

## Milestone 1 — Killer DX: LiveView Media Component (v0.5.1) ✅

**Goal**: Ship a ready-to-use LiveView component that eliminates 150+ lines of upload boilerplate.

**Status**: Complete. All core sub-items implemented. The `MediaLive` LiveComponent provides the zero-boilerplate "drop one component" experience. The lower-level `<.media_upload>`, `<.media_gallery>`, and `LiveUpload` helpers provide full control for custom UIs. Only drag-and-drop reordering (`.MediaSortable`) remains deferred to Milestone 4.

This is the single highest-impact feature for adoption. Every Phoenix developer who handles file uploads writes the same code over and over. We eliminate that.

### 1.0 — `PhxMediaLibrary.MediaLive` — Zero-Boilerplate LiveComponent *(v0.5.1)*

- [x] Self-contained LiveComponent that encapsulates upload + gallery lifecycle
- [x] No `use PhxMediaLibrary.LiveUpload`, no `handle_event`, no `allow_upload`, no `consume_media` needed
- [x] Drag-and-drop upload zone, live image previews, progress bars, error display, cancel buttons
- [x] Stream-powered media gallery with delete-on-hover
- [x] Dark mode support
- [x] Configurable: `max_file_size`, `max_entries`, `responsive`, `upload_label`, `upload_sublabel`, `compact`, `columns`, `conversion`, `show_gallery`, `class`
- [x] Style override: `upload_class`, `gallery_class`, `button_class` for full customization (daisyUI, etc.)
- [x] Sends `{PhxMediaLibrary.MediaLive, {:uploaded, collection, media_items}}` and `{PhxMediaLibrary.MediaLive, {:deleted, collection, media}}` messages to parent

```elixir
# The simplest possible media upload — this is ALL a developer needs:
<.live_component
  module={PhxMediaLibrary.MediaLive}
  id="post-images"
  model={@post}
  collection={:images}
/>
```

**Status**: ✅ Done (v0.5.1). This is the recommended approach for most use cases. For full control, use the lower-level `<.media_upload>` + `<.media_gallery>` + `LiveUpload` helpers below.

### 1.1 — `<.media_upload>` Component

- [x] Drop-in LiveView component for uploading media to a model
- [x] Handles `allow_upload`, `validate`, `save`, and `consume_uploaded_entries` internally (via `LiveUpload` helpers)
- [x] Drag-and-drop zone with visual feedback (phx-drop-target + colocated `.MediaDropZone` JS hook)
- [x] Upload progress bar per file
- [x] Image preview before upload (client-side via `<.live_img_preview>`)
- [x] Error display (file too large, wrong type, max files exceeded)
- [x] Configurable via attrs: label, sublabel, compact, disabled, cancel_event, cancel_target
- [x] Emits events the parent LiveView can hook into (`:media_added`, `:media_removed`, `:media_error`) — via `:notify` option on `consume_media/5` and `delete_media_by_id/2`. When set to a pid, sends `{:media_added, media_items}`, `{:media_removed, media}`, or `{:media_error, reason}` to the process for `handle_info/2`

```elixir
# The actual API — this is all a developer needs:
<.media_upload
  upload={@uploads.images}
  id="post-images-upload"
  label="Upload Images"
  sublabel="JPG, PNG, WebP up to 10MB"
/>
```

### 1.2 — `<.media_gallery>` Component

- [x] Display existing media for a model/collection (works with LiveView streams)
- [x] Delete button per item with confirmation (configurable confirm_delete, confirm_message)
- [x] Thumbnail display for images, icon for documents (auto-detected by MIME type)
- [ ] Drag-and-drop reordering (deferred to Milestone 4 — needs JS + reorder API)
- [x] Empty state (via `:empty` slot + CSS `:only-child` pattern)
- [x] Customizable item rendering via `:item` slot

```elixir
<.media_gallery
  media={@streams.media}
  id="post-gallery"
>
  <:item :let={{id, media}}>
    <.media_img media={media} conversion={:thumb} class="rounded-lg" />
  </:item>
  <:empty>
    <p>No images yet. Upload some above!</p>
  </:empty>
</.media_gallery>
```

### 1.3 — `PhxMediaLibrary.LiveUpload` Helper Module

- [x] `use PhxMediaLibrary.LiveUpload` — imports all helper functions into a LiveView
- [x] `allow_media_upload(socket, :images, model: post, collection: :images)` — wraps `allow_upload` with collection-aware defaults (auto-derives accept types, max entries, max file size from collection config)
- [x] `consume_media(socket, :images, post, :images)` — wraps `consume_uploaded_entries` and calls `PhxMediaLibrary.add/2 |> to_collection/2` for each entry
- [x] Handles both single-file and multi-file collections automatically (derives max_entries from single_file/max_files)
- [x] `stream_existing_media/4` — loads and streams existing media for display
- [x] `stream_media_items/3` — inserts newly created media into a stream
- [x] `delete_media_by_id/1` — fetches and deletes media by ID
- [x] `media_upload_errors/1`, `media_entry_errors/2` — human-readable error helpers
- [x] `has_upload_entries?/1`, `image_entry?/1` — introspection helpers
- [ ] Provide default `handle_event` implementations that can be overridden (deferred — keeping it explicit is better DX for now)

```elixir
defmodule MyAppWeb.PostLive.FormComponent do
  use MyAppWeb, :live_view
  use PhxMediaLibrary.LiveUpload

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:post, post)
     |> allow_media_upload(:images, collection: :images, for: post)}
  end

  def handle_event("save", params, socket) do
    # consume_media handles all the file storage and DB persistence
    {:ok, media_items} = consume_media(socket, :images, socket.assigns.post)
    # ... rest of save logic
  end
end
```

### 1.4 — JS Hooks for Client-Side UX

- [x] Use colocated JS hooks (Phoenix 1.8 style with `.HookName` prefix)
- [x] `.MediaDropZone` — drag-and-drop with visual states (idle, hover, active, dropped flash)
- [x] `.MediaPreview` — handled natively by `<.live_img_preview>` (no custom hook needed)
- [ ] `.MediaSortable` — drag-and-drop reordering (deferred to Milestone 4 — needs reorder API)
- [x] `.MediaProgress` — CSS transition-based smooth progress bar (no JS hook needed)

### 1.5 — Default Styles

- [x] Ship Tailwind CSS classes that work out of the box
- [x] Respect the user's design system — components should be customizable, not opinionated (all components accept `:class`, `:item` slot, `:drop_zone` slot for full override)
- [x] Provide sensible defaults that look good without any customization
- [x] Dark mode support via Tailwind's `dark:` variants
- [x] All styles in component attrs, never in external CSS (so users can override everything)
- [x] `<.media_upload_button>` — compact inline variant for embedding in forms
- [x] `phx-drop-target-active:` custom variant documented for consumer app CSS setup

### 1.6 — Multi-file Selection & Progress Bar Fixes *(v0.5.1)*

- [x] Non-`single_file` collections default to `max_entries: 10` (enables `multiple` attribute on file input)
- [x] Progress bar track rendered at `progress >= 0` (visible on fast/local uploads)
- [x] Percentage label during upload, "Ready" checkmark at 100%

---

## Milestone 2 — Make the Core Solid ✅

**Goal**: Fix critical issues that would block production use.

**Status**: Complete. All sub-items implemented, 370 tests passing (297 unit + 17 Oban worker + 56 integration).

### 2.1 — Make `:image` (libvips) Optional

- [x] Move `{:image, "~> 0.54"}` to optional dependency
- [x] Core library must compile and work without it (file storage, collections, DB persistence)
- [x] Image processing features gracefully degrade when `:image` is not available
- [ ] Add `PhxMediaLibrary.ImageProcessor.Mogrify` as alternative adapter (also optional)
- [x] Clear error messages when user tries to use conversions without an image processor installed
- [x] Wrap all optional-dep modules in `if Code.ensure_loaded?` compile guards (v0.5.1 — S3 adapter added)

**Status**: ✅ Done (except Mogrify adapter — deferred to a future milestone).
`:image` is `optional: true` in `mix.exs`. `ImageProcessor.Image` is wrapped in `if Code.ensure_loaded?(Image)`. `ImageProcessor.Null` provides clear error messages guiding the developer. `Config.image_processor/0` auto-detects the available backend.

**v0.5.1 update**: `Storage.S3` now also wrapped in `if Code.ensure_loaded?(ExAws.S3)`, matching the pattern used by `ImageProcessor.Image` and `AsyncProcessor.Oban`. Consumer projects without S3 deps no longer see ~15 noisy `ExAws.S3.* is undefined` compile warnings.

**Why**: Many users just need file attachments (PDFs, CSVs, documents). Requiring libvips installation to store a PDF is a dealbreaker.

### 2.2 — Integration Tests with Real Database

- [x] Wire up `TestRepo` with `Ecto.Adapters.SQL.Sandbox`
- [x] Add migration for test database
- [x] Write integration tests for the full flow: `add → store → retrieve → convert → delete`
- [x] Test collection validation (MIME types, single file, max files)
- [x] Test the `MediaAdder` pipeline end-to-end
- [x] Test storage adapters with real files (using `tmp_dir` tag)
- [x] Test error paths (missing files, invalid types, storage failures)

**Status**: ✅ Done. 56 integration tests in `test/phx_media_library/integration_test.exs` exercise the full lifecycle against a real Postgres database using `Ecto.Adapters.SQL.Sandbox`. Tests are tagged with `@moduletag :db` and automatically excluded when Postgres is unavailable. Covers: full add→store→retrieve→delete flow, collection MIME validation, single_file replacement, max_files enforcement (with a bug fix for oldest-first deletion), ordering, checksum integrity verification (including tamper detection), polymorphic type scoping, `has_many` preloading, `media_query/2` composability, clear/delete operations, error paths, disk and memory storage adapters, and concurrent access.

**Why**: The current tests only verify struct creation. The actual persist-and-retrieve path is untested.

### 2.3 — Fix Oban Worker

- [x] Resolve full `Conversion` definitions in the Oban worker (not just names)
- [x] Store the `mediable_type` in the job args so we can look up the model module
- [x] Look up the model's `media_conversions/0` and match by name to get full config
- [x] Add proper error handling and logging
- [x] Add test for the Oban worker (using `Oban.Testing`)
- [x] Extract `find_model_module/1` into `PhxMediaLibrary.ModelRegistry` (v0.5.1) — always compiled, no Oban dependency

**Status**: ✅ Done. 17 dedicated tests in `test/phx_media_library/workers/process_conversions_test.exs` using `Oban.Testing.perform_job/3`. The `Workers.ProcessConversions` worker now stores `mediable_type` in job args, discovers the originating schema module via `ModelRegistry.find_model_module/1` (using a persistent_term cache), retrieves full `Conversion` definitions from the model's `get_media_conversions/1` or `media_conversions/0`, and filters by requested names. Handles legacy job args gracefully. Includes proper logging for missing media, unresolvable modules, and empty conversion lists. Tests cover: missing media discard, conversion resolution from TestPost (full definitions with dimensions/quality/fit), collection-scoped conversions, legacy args fallback, unknown mediable_type fallback, model module discovery and caching, explicit model registry, and job changeset construction.

**v0.5.1 update**: The model discovery logic (`find_model_module/1`, `get_model_conversions/2`, persistent_term cache) was extracted into `PhxMediaLibrary.ModelRegistry` — an always-compiled module with no optional dependencies. The Oban worker and `mix phx_media_library.regenerate` both delegate to it. `ProcessConversions.find_model_module/1` remains as a `defdelegate` for backwards compatibility.

**Why**: The current Oban worker creates empty `Conversion` structs with only a name — no dimensions, no quality, no fit mode. Async processing is broken.

### 2.4 — Hybrid `has_many` + Query Helpers

- [x] Inject `has_many :media, PhxMediaLibrary.Media, ...` via the `has_media()` macro
- [x] Support `Repo.preload(post, :media)` for natural Ecto usage
- [x] Keep `get_media(post, :images)` query helpers for collection-filtered access
- [x] Handle the polymorphic foreign key setup (mediable_type + mediable_id)
- [x] Consider whether `has_many` can use `:where` option for collection-scoped associations

**Status**: ✅ Done. `has_media()` injects a polymorphic `has_many :media` using `Ecto.Schema.__has_many__/4` directly (bypassing macro-expansion timing issues with Ecto's schema block). Uses `:where` for `mediable_type` scoping and `:defaults` for auto-populating on build. `has_media(:images)` creates collection-scoped `has_many :images` with both `mediable_type` and `collection_name` in the `:where` clause. The media type is resolved at module compilation time (not macro expansion time) from `@ecto_struct_fields` or the explicit override. `PhxMediaLibrary.media_query/2` provides composable Ecto queries. Integration tests verify `Repo.preload(post, [:media, :images, :documents, :avatar])`.

**Why**: `Repo.preload(post, :media)` is how every Ecto developer expects associations to work. The current query-only approach feels foreign.

### 2.5 — Checksum Computation and Storage

- [x] Add `checksum` and `checksum_algorithm` fields to the Media schema
- [x] Compute SHA-256 checksum during upload (before storage)
- [x] Store checksum in the database
- [x] Add `Media.verify_integrity/1` to check stored file against checksum
- [x] Update migration template
- [ ] Consider using checksum for deduplication (optional)

**Status**: ✅ Done (except deduplication — deferred to Parking Lot). `Media` schema has `checksum` and `checksum_algorithm` fields. `MediaAdder.store_and_persist/4` computes SHA-256 before storage via `Media.compute_checksum/2` (supports sha256, sha1, md5). `Media.verify_integrity/1` re-reads from storage and compares. Migration `20240101000002_add_checksum_to_media.exs` adds the columns and an index. Integration tests verify correct checksum storage, untampered file verification, and tamper detection.

**Why**: Essential for data integrity verification, especially with cloud storage.

### 2.6 — Fix Polymorphic Type Derivation

- [x] Replace naive `Module.split |> List.last |> append "s"` with configurable approach
- [x] Option 1: Let schema define `@media_type "blog_posts"` via `HasMedia`
- [x] Option 2: Use full module name, underscored (e.g., `"my_app/blog/post"`)
- [x] Option 3: Derive from Ecto schema source (table name) — most reliable ← **chosen**
- [x] Whichever we pick, make it overridable per-schema
- [ ] Add migration guide for changing existing mediable_type values

**Status**: ✅ Done (except migration guide — deferred to docs milestone). Default: `__schema__(:source)` (the Ecto table name, e.g. `"posts"`, `"blog_categories"`). Override via `use PhxMediaLibrary.HasMedia, media_type: "blog_posts"` or by defining `def __media_type__, do: "custom"`. Priority: 1) user-defined `__media_type__/0`, 2) explicit `:media_type` option, 3) Ecto table source, 4) underscored module name fallback. The `has_media()` macro, `MediaAdder`, `Media.get_mediable_info/1`, and `PhxMediaLibrary.get_mediable_type/1` all use the same resolution logic. Tests cover all derivation paths.

**Why**: `"posts"` works for `Post`, but `"categorys"` for `Category` is wrong. Deriving from the Ecto table source (`__schema__(:source)`) is the most robust default.

### 2.7 — Schema-Level Configuration DSL

- [x] Replace function-based `media_collections/0` with a declarative macro DSL
- [x] Collections and conversions defined at compile-time in the schema body
- [x] App-level config only for global defaults (repo, storage disks)
- [x] Schema-level config overrides app-level
- [x] Nested `collection ... do convert ... end` syntax (v0.5.1) — conversions auto-scoped to enclosing collection
- [x] `NestedConversionAccumulator` provides `convert/2` inside collection blocks
- [x] Nested and flat styles mixable freely; explicit `:collections` respected inside nested blocks

**Status**: ✅ Done. `media_collections do ... end` and `media_conversions do ... end` macros accumulate `Collection` and `Conversion` structs via module attributes at compile time. `CollectionAccumulator` and `ConversionAccumulator` provide the in-block macros. `__before_compile__` injects `media_collections/0` and `media_conversions/0` using `defoverridable` to replace the default empty-list implementations. The DSL and function-based styles are mutually exclusive per concern but can be mixed (e.g. DSL collections + function conversions). `convert/2` is an alias for `conversion/2` that reads more naturally in the DSL context. Tests verify DSL, function-based, mixed, nested, and minimal schemas.

**v0.5.1 update**: Added nested `collection ... do ... end` syntax via `NestedConversionAccumulator`. This is now the **recommended style** — conversions are auto-scoped to their enclosing collection, eliminating the need for explicit `:collections` options. The flat style remains supported for shared conversions or developer preference.

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  schema "posts" do
    field :title, :string
    has_media()
    timestamps()
  end

  # Recommended: nested style (v0.5.1+)
  media_collections do
    collection :images, disk: :s3, max_files: 20 do
      convert :thumb, width: 150, height: 150, fit: :cover
      convert :preview, width: 800, quality: 85
      convert :banner, width: 1200, height: 400, fit: :crop
    end

    collection :documents, accepts: ~w(application/pdf)

    collection :avatar, single_file: true, fallback_url: "/images/default.png" do
      convert :thumb, width: 150, height: 150, fit: :cover
    end
  end
end
```

**Why**: This reads more naturally than returning lists from functions. It's the Ecto DSL philosophy — declare your data model, don't configure it from afar. The nested style makes scoping visually explicit — you can see at a glance which conversions apply to which collections.

---

## Milestone 3a — Error Handling & Validation Hardening (v0.3.0) ✅

**Goal**: Establish consistent error handling, add production-critical validations, and fix N+1 batch operations.

### 3.1 — Robust Error Handling

- [x] Custom exception structs: `PhxMediaLibrary.Error`, `PhxMediaLibrary.StorageError`, `PhxMediaLibrary.ValidationError`
- [x] Consistent error tuples across all operations
- [x] Provide `!` bang versions for key functions (e.g., `add!/2`, `to_collection!/3`)
- [x] Telemetry events for monitoring:
  - `[:phx_media_library, :add, :start | :stop | :exception]`
  - `[:phx_media_library, :delete, :start | :stop | :exception]`
  - `[:phx_media_library, :conversion, :start | :stop | :exception]`
  - `[:phx_media_library, :storage, :start | :stop | :exception]`
- [x] Logger integration for debugging

### 3.2 — File Size Validation

- [x] Add `:max_size` option to collection configuration
- [x] Validate file size before storage (not after)
- [x] Return clear error: `{:error, {:file_too_large, size, max_size}}`
- [x] Integrate with LiveView upload's `max_file_size` option automatically

### 3.3 — Content-Based MIME Type Detection

- [x] `PhxMediaLibrary.MimeDetector` behaviour for pluggable detection
- [x] Default implementation using magic bytes for common types (images, PDF, video, audio, zip)
- [x] Use as primary detection, fall back to extension
- [x] Reject files where content doesn't match extension (configurable via `:verify_content_type` collection option, default `true`)

### 3.4 — Batch Operations

- [x] `clear_collection/2` — single query delete + batch file removal (fix N+1)
- [x] `clear_media/1` — single query delete + batch file removal (fix N+1)
- [x] `reorder/3` — `PhxMediaLibrary.reorder(post, :images, [id3, id1, id2])` using single transaction
- [x] `move_to/2` — move a single media item to a position
- [x] Emit `:media_reordered` Telemetry event

## Milestone 3b — Remote URLs, Metadata & Oban Enhancements (v0.4.0) ✅

**Goal**: Enhance remote URL support, add automatic metadata extraction, and improve Oban integration.

### 3b.1 — Remote URL Sources (Enhanced)

- [x] URL validation — only `http`/`https` schemes accepted; descriptive `{:error, {:invalid_url, reason}}` tuples for `ftp://`, `file://`, missing host, non-string
- [x] Custom request headers — `add_from_url/3` accepts `:headers` option for authenticated downloads
- [x] Download timeout — `:timeout` option sets a receive timeout for slow servers
- [x] Download telemetry — `[:phx_media_library, :download, :start | :stop | :exception]` events with URL, size, and MIME type metadata
- [x] Source URL tracking — original URL automatically stored in `custom_properties["source_url"]`
- [x] Broader success codes — downloads now accept any 2xx status code (200–299), not just 200

### 3b.2 — Automatic Metadata Extraction

- [x] `PhxMediaLibrary.MetadataExtractor` behaviour with `extract/3` callback
- [x] `PhxMediaLibrary.MetadataExtractor.Default` — image dimensions/EXIF via `:image`, type classification, format normalization for 50+ MIME types
- [x] `metadata` JSON column on Media schema (separate from `custom_properties`)
- [x] New migration `add_metadata_to_media` + install task updated to include `metadata` from the start
- [x] Auto-extraction in `to_collection/3` pipeline (after MIME detection, before storage)
- [x] `without_metadata/1` — opt-out per-upload
- [x] Global disable via `config :phx_media_library, extract_metadata: false`
- [x] Custom extractor via `config :phx_media_library, metadata_extractor: MyModule`
- [x] Non-fatal — extraction failures log a warning but never block the upload
- [x] Every extracted metadata includes `"extracted_at"` ISO 8601 timestamp

### 3b.3 — Oban Conversion Queuing (Enhanced)

- [x] `process_sync/2` — synchronous processing callback on `AsyncProcessor.Oban` for immediate conversions
- [x] Enhanced documentation — full setup walkthrough, queue sizing guidance, retry behaviour docs

## Milestone 3c — Production Hardening (v0.5.0) ✅

**Goal**: Add soft deletes, streaming, and direct S3 uploads for large-scale production use.

### 3.5 — Soft Deletes

- [x] Add optional `deleted_at` field to Media schema
- [x] `delete/1` sets `deleted_at` instead of removing (when enabled via `config :phx_media_library, soft_deletes: true`)
- [x] `permanently_delete/1` for actual removal (always hard-deletes regardless of config)
- [x] Scoping: all queries (`get_media`, `media_query`, `get_first_media`) exclude soft-deleted by default
- [x] `restore/1` to undelete (clears `deleted_at`)
- [x] `mix phx_media_library.purge_deleted` task to permanently delete old soft-deleted media (with `--days`, `--all`, `--dry-run` options)
- [x] Make soft deletes opt-in via config (`soft_deletes: false` by default)
- [x] `trashed?/1` predicate, `get_trashed_media/2`, `purge_trashed/2` API functions
- [x] `clear_collection/2` and `clear_media/1` soft-delete when enabled (files preserved until purge)
- [x] `exclude_trashed/1` and `only_trashed/1` query helpers on `Media`
- [x] Install task updated with `deleted_at` column and index

### 3.6 — Streaming Upload Support (scoped)

- [x] Replace `File.read!` in `MediaAdder` with streaming from file to storage (64 KB chunks)
- [x] Compute SHA-256 checksum during streaming in a single pass (not as a separate read)
- [x] Read only first 512 bytes for MIME detection (magic bytes), not entire file
- [x] All three storage adapters (Disk, Memory, S3) already handle `{:stream, stream}` content
- [x] Known issue "MediaAdder loads entire file into memory" — resolved
- [ ] **Deferred to M4**: Full `{:stream, enumerable}` pipeline support for caller-provided streams

### 3.7 — Direct S3 Upload (Presigned URLs)

- [x] `presigned_upload_url/3` — generate presigned URLs for client-to-S3 uploads
- [x] `complete_external_upload/4` — create Media record after client uploads directly to storage
- [x] `presigned_upload_url/3` callback added to `PhxMediaLibrary.Storage` behaviour (optional)
- [x] S3 adapter implements `presigned_upload_url/3` with `:expires_in`, `:content_type`, `:content_length_range` options
- [x] `StorageWrapper.presigned_upload_url/3` returns `{:error, :not_supported}` for adapters without the callback
- [x] Telemetry events emitted for external uploads (`[:phx_media_library, :add]`)
- [x] Supports pre-computed checksums from client-side hashing
- [ ] **Deferred to M4**: `<.media_upload>` variant that auto-detects S3 and uses external uploads
- [ ] **Deferred to M4**: LiveView external upload integration via `allow_media_upload/3` `:external` option

---

## Milestone 4 — Best-in-Class

**Goal**: Features that make this library the definitive choice in the ecosystem.

### 4.1 — Blurhash Generation

- [ ] Generate blurhash strings as an alternative to tiny JPEG placeholders
- [ ] Store in `responsive_images` metadata
- [ ] Ship a `<.blurhash>` component that renders the placeholder client-side
- [ ] Much smaller payload than base64 JPEG placeholders

### 4.2 — Video Support

- [ ] Extract video thumbnails (via FFmpeg adapter)
- [ ] Store video metadata (duration, resolution, codec)
- [ ] Generate video preview (short clip / GIF)
- [ ] `<.media_video>` component with poster frame

### 4.3 — Multi-Tenant Support

- [ ] Scoped storage paths: `{tenant_id}/{mediable_type}/{id}/...`
- [ ] Per-tenant storage configuration (different S3 buckets)
- [ ] Query scoping by tenant

### 4.4 — Content Delivery Optimization

- [ ] CDN URL generation with cache-busting (checksum in URL)
- [ ] Signed/expiring URLs for private media
- [ ] On-the-fly image transformation URLs (like Imgix/Cloudinary)
- [ ] Content-Disposition headers for download links

### 4.5 — Admin & Debugging Tools

- [ ] Mix task: `mix phx_media_library.stats` — show storage usage per model/collection
- [ ] Mix task: `mix phx_media_library.doctor` — diagnose common issues (missing files, orphaned records, broken conversions)
- [ ] Optional LiveDashboard page showing media stats

### 4.6 — Custom Path Generator Behaviour

- [ ] Allow users to define their own path structure
- [ ] Default: `{mediable_type}/{mediable_id}/{uuid}/{filename}`
- [ ] Flat: `{uuid}/{filename}`
- [ ] Date-based: `{year}/{month}/{day}/{uuid}/{filename}`

---

## Design Decisions

Decisions made or pending that affect the library's architecture.

### Decided

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary API style | Fluent pipeline (`post \|> add(upload) \|> to_collection(:images)`) | Mirrors Spatie, feels natural in Elixir |
| Storage abstraction | Behaviour-based adapters | Clean separation, easy to extend |
| Async processing | Behaviour with Task (default) and Oban (optional) | Simple default, robust option available |
| Config for global defaults | Application environment | Standard Elixir convention for library config |
| Primary key type | Binary UUID | More portable, works across databases |

### Pending

| Decision | Options | Notes |
|----------|---------|-------|
| Library name | `PhxMediaLibrary`, `PhxMedia`, `ExMedia`, `Mediator` | Parking for later. `Phx` prefix implies Phoenix-only but core is Ecto-only |

### Recently Decided (Milestones 2 & v0.5.1)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Schema DSL style | Both: macro blocks (`media_collections do ... end`) + function-based (`def media_collections, do: [...]`). Nested `collection ... do convert ... end` as recommended style (v0.5.1) | DSL reads more naturally; nested style makes conversion scoping visually explicit. Function style preserved for backwards compat. Mutually exclusive per concern but mixable. See 2.7 |
| Polymorphic type derivation | Ecto table name (`__schema__(:source)`) as default, overridable via `use` option or `def __media_type__/0` | Table name is the most robust default — no naive pluralization. Priority: user-defined fn > explicit option > table source > module name fallback. See 2.6 |
| `has_many` injection | Via `has_media()` macro inside the schema block, calling `Ecto.Schema.__has_many__/4` directly at module compilation time | Bypasses macro-expansion timing issues with Ecto's schema block. Uses `:where` for polymorphic scoping, `:defaults` for auto-populating. Collection-scoped variants via `has_media(:images)`. See 2.4 |
| LiveView component architecture | Three tiers: `MediaLive` LiveComponent (zero-boilerplate, v0.5.1) → `<.media_upload>` + `<.media_gallery>` (composable) → `LiveUpload` helpers (full control) | `MediaLive` for quick start; function components for layout control; helper module for complete customization. See 1.0–1.3 |
| Optional dep compile guards | All optional-dep modules wrapped in `if Code.ensure_loaded?` | Prevents noisy warnings in consumer projects. Pattern: `ImageProcessor.Image`, `AsyncProcessor.Oban`, `Storage.S3` (v0.5.1). See 2.1 |
| Model module discovery | `PhxMediaLibrary.ModelRegistry` (always compiled, v0.5.1) with persistent_term cache | Decoupled from Oban worker so mix tasks and non-Oban setups can discover model modules. See 2.3 |
| Optional image processing | `:image` marked `optional: true`; `ImageProcessor.Null` as fallback with clear error messages; `Config.image_processor/0` auto-detects | Library works for file storage without libvips. See 2.1 |
| Checksum strategy | SHA-256 computed before storage, stored alongside media record | Supports sha256/sha1/md5. `verify_integrity/1` re-reads and compares. See 2.5 |

---

## Known Issues

Active bugs or problems in the current codebase.

- [x] **Oban worker creates empty Conversion structs** — only name is set, no dimensions/quality/format. Async processing produces broken conversions. (Fixed in Milestone 2.3)
- [x] **`:image` is a hard required dependency** — library won't compile without libvips installed. (Fixed in Milestone 2.1)
- [x] **Pluralization is naive** — `get_mediable_type/1` just appends "s" to the module name. Breaks for irregular plurals. (Fixed in Milestone 2.6 — now derives from Ecto table name)
- [x] **`String.to_existing_atom/1` in `Config.disk_config/1`** — crashes if atom doesn't exist yet. (Fixed — now iterates disk keys and compares strings)
- [x] **No integration tests** — core `to_collection/3` path is untested against a real database. (Fixed in Milestone 2.2 — 56 integration tests)
- [x] **`has_media()` macro is a no-op** — doesn't inject any association. (Fixed in Milestone 2.4 — injects polymorphic `has_many`)
- [x] **`clear_collection/2` and `clear_media/1` are N+1** — fetch all, then delete one-by-one. (Fixed in Milestone 3.4 — single `delete_all` query with batch file removal)
- [x] **`PathGenerator.full_path/2` uses `Keyword.keys(__info__(:functions))`** — fragile way to check for optional callback implementation. (Fixed — now uses `Code.ensure_loaded/1` + `function_exported?/3`)
- [x] **`max_files` cleanup deletes newest items instead of oldest** — `Enum.drop(max)` on ascending-ordered list removes the newest item. (Fixed — now keeps newest `max` items, deletes oldest excess)
- [x] **No file size validation** — collections can't limit upload size. (Fixed in Milestone 3.2 — `:max_size` collection option, validated before storage)
- [x] **MIME detection is extension-only** — no content-based verification. (Fixed in Milestone 3.3 — `MimeDetector` behaviour with magic-bytes default, `:verify_content_type` collection option)
- [x] **`MediaAdder` loads entire file into memory** — `File.read!` before storage. (Fixed in Milestone 3c/3.6 — now streams in 64 KB chunks with single-pass checksum)
- [x] **~15 noisy ExAws/S3 compile warnings in consumer projects** — `Storage.S3` was unconditionally compiled, producing `ExAws.S3.* is undefined` warnings for projects without S3 deps. (Fixed in v0.5.1 — wrapped in `if Code.ensure_loaded?(ExAws.S3)`)
- [x] **`ProcessConversions.find_model_module/1 is undefined` warning in `mix phx_media_library.regenerate`** — the mix task referenced `ProcessConversions` which only exists when Oban is installed. (Fixed in v0.5.1 — extracted to `ModelRegistry`)
- [x] **Multi-file selection broken by default** — non-`single_file` collections without `max_files` defaulted to `max_entries: 1` (Phoenix LiveView default), disabling the `multiple` attribute. (Fixed in v0.5.1 — defaults to `max_entries: 10`)
- [x] **Upload progress bars invisible on fast/local uploads** — progress bar only rendered when `progress > 0`, but local uploads complete instantly. (Fixed in v0.5.1 — renders at `progress >= 0`)

---

## Parking Lot

Ideas and suggestions that don't have a home yet.

- **Naming discussion** — consider renaming the library for a shorter, more memorable name
- **Ex Machina / test factory integration** — helpers for generating media fixtures in consumer app tests
- **Ecto multi integration** — wrap add/delete operations in `Ecto.Multi` for transactional safety
- **Pluggable filename sanitization** — let users define their own sanitization rules
- **Internationalized filenames** — handle Unicode filenames properly (transliteration)
- **Quota system** — per-model or per-user storage limits
- **Webhook/event system** — beyond Telemetry, allow users to subscribe to media lifecycle events
- **Pre-signed download URLs** — for private files with expiring access
- **Zip download** — download all media in a collection as a zip archive
- **Duplicate detection** — use checksums to detect and optionally prevent duplicate uploads
- ~~**Image metadata extraction** — EXIF data, GPS coordinates, camera info~~ (Done in Milestone 3b.2)
- **Auto-rotation** — fix EXIF orientation on upload