# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/mike-kostov/phx_media_library/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mike-kostov/phx_media_library/releases/tag/v0.1.0