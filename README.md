# PhxMediaLibrary

[![Hex.pm](https://img.shields.io/hexpm/v/phx_media_library.svg)](https://hex.pm/packages/phx_media_library)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/phx_media_library)
[![License](https://img.shields.io/hexpm/l/phx_media_library.svg)](https://github.com/mike-kostov/phx_media_library/blob/main/LICENSE)

A robust, Ecto-backed media management library for Elixir and Phoenix, inspired by [Spatie's Laravel Media Library](https://spatie.be/docs/laravel-medialibrary).

## Features

- **Associate files with Ecto schemas** - Polymorphic media associations
- **Collections** - Organize media into named collections with validation
- **Image conversions** - Generate thumbnails, previews, and custom sizes
- **Responsive images** - Automatic srcset generation for optimal loading
- **Multiple storage backends** - Local filesystem, S3, or custom adapters
- **Async processing** - Background conversion processing with Oban support
- **Phoenix components** - Ready-to-use view helpers for templates

## Installation

Add `phx_media_library` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phx_media_library, "~> 0.1.0"},

    # Optional: For S3 storage
    {:ex_aws, "~> 2.5"},
    {:ex_aws_s3, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},

    # Optional: For async processing with Oban
    {:oban, "~> 2.18"}
  ]
end
```

## Configuration

Add the required configuration to your `config/config.exs`:

```elixir
config :phx_media_library,
  repo: MyApp.Repo,
  default_disk: :local,
  disks: [
    local: [
      adapter: PhxMediaLibrary.Storage.Disk,
      root: "priv/static/uploads",
      base_url: "/uploads"
    ]
  ]
```

### Storage Options

#### Local Disk (Default)

```elixir
config :phx_media_library,
  disks: [
    local: [
      adapter: PhxMediaLibrary.Storage.Disk,
      root: "priv/static/uploads",
      base_url: "/uploads"
    ]
  ]
```

#### Amazon S3

```elixir
config :phx_media_library,
  default_disk: :s3,
  disks: [
    s3: [
      adapter: PhxMediaLibrary.Storage.S3,
      bucket: "my-bucket",
      region: "us-east-1"
    ]
  ]

# Configure ExAws credentials
config :ex_aws,
  access_key_id: {:system, "AWS_ACCESS_KEY_ID"},
  secret_access_key: {:system, "AWS_SECRET_ACCESS_KEY"}
```

### Responsive Images (Optional)

```elixir
config :phx_media_library,
  responsive_images: [
    enabled: true,
    widths: [320, 640, 960, 1280, 1920],
    tiny_placeholder: true
  ]
```

### Async Processing with Oban (Optional)

```elixir
config :phx_media_library,
  async_processor: PhxMediaLibrary.AsyncProcessor.Oban
```

## Quick Start

### 1. Run the installer

```bash
mix phx_media_library.install
mix ecto.migrate
```

This generates the `media` table migration with all required fields.

### 2. Add to your Ecto schema

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  schema "posts" do
    field :title, :string
    has_media()
    timestamps()
  end

  # Define collections for organizing media
  def media_collections do
    [
      collection(:images),
      collection(:documents, accepts: ~w(application/pdf)),
      collection(:avatar, single_file: true)
    ]
  end

  # Define image conversions
  def media_conversions do
    [
      conversion(:thumb, width: 150, height: 150, fit: :cover),
      conversion(:preview, width: 800, quality: 85)
    ]
  end
end
```

### 3. Add media to your models

```elixir
# From a file path
post
|> PhxMediaLibrary.add("/path/to/image.jpg")
|> PhxMediaLibrary.to_collection(:images)

# From a Phoenix upload
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.using_filename("custom-name.jpg")
|> PhxMediaLibrary.with_custom_properties(%{"alt" => "My image"})
|> PhxMediaLibrary.to_collection(:images)

# From a URL
post
|> PhxMediaLibrary.add_from_url("https://example.com/image.jpg")
|> PhxMediaLibrary.to_collection(:images)
```

### 4. Retrieve media

```elixir
# Get all media in a collection
PhxMediaLibrary.get_media(post, :images)

# Get the first media item
PhxMediaLibrary.get_first_media(post, :images)

# Get URLs
PhxMediaLibrary.get_first_media_url(post, :images)
PhxMediaLibrary.get_first_media_url(post, :images, :thumb)
PhxMediaLibrary.get_first_media_url(post, :images, fallback: "/default.jpg")

# Get URL for a specific media item
PhxMediaLibrary.url(media)
PhxMediaLibrary.url(media, :thumb)
```

## Collections

Collections help organize media and apply validation rules.

```elixir
def media_collections do
  [
    # Basic collection
    collection(:images),

    # With MIME type validation
    collection(:documents, accepts: ~w(application/pdf application/msword)),

    # Single file only (replaces existing)
    collection(:avatar, single_file: true),

    # Limit number of files
    collection(:gallery, max_files: 10),

    # Custom storage disk
    collection(:backups, disk: :s3),

    # Fallback URL when empty
    collection(:profile_photo, single_file: true, fallback_url: "/images/default-avatar.png")
  ]
end
```

## Conversions

Conversions automatically generate derived images when media is added.

```elixir
def media_conversions do
  [
    # Simple resize
    conversion(:thumb, width: 150, height: 150),

    # Resize with fit mode
    conversion(:square, width: 300, height: 300, fit: :cover),

    # Width only (maintains aspect ratio)
    conversion(:preview, width: 800),

    # With quality setting
    conversion(:optimized, width: 1200, quality: 80),

    # Convert format
    conversion(:webp_thumb, width: 150, format: :webp),

    # Only for specific collections
    conversion(:thumb, width: 150, collections: [:images, :gallery])
  ]
end
```

### Fit Options

- `:contain` - Resize to fit within dimensions, maintaining aspect ratio
- `:cover` - Resize to cover dimensions, cropping if necessary
- `:fill` - Stretch to fill dimensions exactly
- `:crop` - Crop to exact dimensions from center

## Responsive Images

Generate multiple sizes for optimal loading across devices.

```elixir
# Enable when adding media
post
|> PhxMediaLibrary.add(upload)
|> PhxMediaLibrary.with_responsive_images()
|> PhxMediaLibrary.to_collection(:images)

# Get srcset attribute
PhxMediaLibrary.srcset(media)
# => "uploads/posts/1/responsive/image-320.jpg 320w, uploads/posts/1/responsive/image-640.jpg 640w, ..."

# Get optimal URL for a specific width
PhxMediaLibrary.Media.url_for_width(media, 800)
```

## View Helpers

Add the view helpers to your Phoenix application:

```elixir
# In your my_app_web.ex
def html_helpers do
  quote do
    # ... existing imports
    import PhxMediaLibrary.ViewHelpers
  end
end
```

### Available Components

#### Simple Image

```heex
<.media_img media={@media} class="rounded-lg" />

<.media_img media={@media} conversion={:thumb} alt="Product image" />
```

#### Responsive Image

```heex
<.responsive_img
  media={@media}
  sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 800px"
  class="w-full h-auto"
  alt="Hero image"
/>

<.responsive_img
  media={@media}
  conversion={:preview}
  sizes="100vw"
  loading="eager"
  placeholder={true}
/>
```

#### Picture Element (Art Direction)

```heex
<.picture
  media={@media}
  sources={[
    %{media: "(max-width: 768px)", conversion: :mobile},
    %{media: "(min-width: 769px)", conversion: :desktop}
  ]}
  alt="Responsive artwork"
/>
```

#### Manual srcset

```heex
<img
  src={PhxMediaLibrary.url(@media)}
  srcset={PhxMediaLibrary.srcset(@media)}
  sizes="100vw"
  alt="My image"
/>
```

## Mix Tasks

### Install

Generate the media table migration:

```bash
mix phx_media_library.install

# Options
mix phx_media_library.install --no-migration    # Skip migration
mix phx_media_library.install --table my_media  # Custom table name
```

### Regenerate Conversions

Regenerate conversions for existing media (useful after changing conversion settings):

```bash
# Regenerate a specific conversion
mix phx_media_library.regenerate --conversion thumb

# Regenerate all conversions
mix phx_media_library.regenerate --all

# For a specific collection
mix phx_media_library.regenerate --conversion thumb --collection images
```

### Regenerate Responsive Images

```bash
mix phx_media_library.regenerate_responsive

# For specific collection
mix phx_media_library.regenerate_responsive --collection images
```

### Clean Orphaned Files

Remove files that exist on disk but have no database record:

```bash
# Dry run - see what would be deleted
mix phx_media_library.clean

# Actually delete orphaned files
mix phx_media_library.clean --force
```

### Generate Custom Migration

Add custom fields to the media table:

```bash
mix phx_media_library.gen.migration add_blurhash_field
```

## Deleting Media

```elixir
# Delete a single media item
PhxMediaLibrary.delete(media)

# Clear all media in a collection
PhxMediaLibrary.clear_collection(post, :images)

# Clear all media for a model
PhxMediaLibrary.clear_media(post)
```

## Custom Storage Adapters

Implement the `PhxMediaLibrary.Storage` behaviour:

```elixir
defmodule MyApp.Storage.CustomAdapter do
  @behaviour PhxMediaLibrary.Storage

  @impl true
  def put(path, content, opts) do
    # Store content at path
    :ok
  end

  @impl true
  def get(path, opts) do
    # Return {:ok, binary} or {:error, reason}
  end

  @impl true
  def delete(path, opts) do
    :ok
  end

  @impl true
  def exists?(path, opts) do
    true
  end

  @impl true
  def url(path, opts) do
    "https://my-cdn.com/#{path}"
  end
end
```

Then configure it:

```elixir
config :phx_media_library,
  disks: [
    custom: [
      adapter: MyApp.Storage.CustomAdapter,
      # Your adapter-specific options
    ]
  ]
```

## Error Handling

Functions that can fail return tagged tuples:

```elixir
case PhxMediaLibrary.to_collection(adder, :images) do
  {:ok, media} ->
    # Success
  {:error, :invalid_mime_type} ->
    # File type not accepted
  {:error, :file_not_found} ->
    # Source file doesn't exist
  {:error, changeset} ->
    # Ecto validation error
end

# Or use the bang version to raise on error
media = PhxMediaLibrary.to_collection!(adder, :images)
```

## Testing

For tests, use the in-memory storage adapter:

```elixir
# config/test.exs
config :phx_media_library,
  repo: MyApp.Repo,
  disks: [
    local: [
      adapter: PhxMediaLibrary.Storage.Memory
    ]
  ]
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Inspired by [Spatie's Laravel Media Library](https://spatie.be/docs/laravel-medialibrary), bringing its excellent developer experience to the Elixir ecosystem.