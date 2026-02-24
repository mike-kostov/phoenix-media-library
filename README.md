# PhxMediaLibrary

A robust, Ecto-backed media management library for Elixir and Phoenix.

PhxMediaLibrary provides a simple, fluent API for:
- Associating files with Ecto schemas
- Organizing media into collections
- Storing files across different storage backends (local, S3)
- Generating image conversions (thumbnails, etc.)
- Creating responsive images for optimal loading

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `phx_media_library` to your list of dependencies in `mix.exs`:

## Quick Start

1. Add `use PhxMediaLibrary.HasMedia` to your Ecto schema
2. Run `mix phx_media_library.install` to generate the migration
3. Start associating media with your models!

```elixir
def deps do
  [
    {:phx_media_library, "~> 0.1.0"}
  ]
end
```

## Mix Tasks

```elixir
# Initial installation
mix phx_media_library.install

# Run the generated migration
mix ecto.migrate

# Regenerate all thumbnails
mix phx_media_library.regenerate --conversion thumb

# See what orphaned files exist (dry run)
mix phx_media_library.clean

# Actually delete orphaned files
mix phx_media_library.clean --force

# Generate a migration to add a custom field
mix phx_media_library.gen.migration add_blurhash_field
```

## Responsive Images Example

```elixir
# Enable responsive images when adding media
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.with_responsive_images()
|> PhxMediaLibrary.to_collection(:images)

# In templates
<.responsive_img
  media={@post.featured_image}
  sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 800px"
  class="rounded-lg shadow-md"
  alt="Featured image"
/>

# Or manually build srcset
<img
  src={PhxMediaLibrary.url(@media)}
  srcset={PhxMediaLibrary.srcset(@media)}
  sizes="100vw"
/>

# Get optimal URL for a specific width
PhxMediaLibrary.Media.url_for_width(@media, 800)
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/phx_media_library>.
