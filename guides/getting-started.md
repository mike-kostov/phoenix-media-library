# Getting Started

This guide walks you through installing PhxMediaLibrary, configuring storage, and adding your first media files.

## Installation

Add `phx_media_library` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phx_media_library, "~> 0.3.0"},

    # Optional: Image processing (requires libvips)
    {:image, "~> 0.54"},

    # Optional: S3 storage
    {:ex_aws, "~> 2.5"},
    {:ex_aws_s3, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},

    # Optional: Async processing with Oban
    {:oban, "~> 2.18"}
  ]
end
```

> **Note:** The `:image` dependency (libvips) is **optional**. PhxMediaLibrary works for file storage (PDFs, CSVs, documents) without it. Image conversions and responsive images require `:image` to be installed. If it's missing, you'll get clear error messages guiding you to install it.

Then fetch dependencies:

```bash
mix deps.get
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

See the [Storage guide](storage.md) for custom adapters and advanced configuration.

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

## Run the Installer

```bash
mix phx_media_library.install
mix ecto.migrate
```

This generates the `media` table migration with all required fields.

## Define Your Schema

PhxMediaLibrary supports two styles for defining collections and conversions. You can use either — or mix them.

### Declarative DSL (recommended)

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  schema "posts" do
    field :title, :string

    has_media()          # injects has_many :media (all media for this model)
    has_media(:images)   # injects has_many :images (scoped to "images" collection)
    has_media(:avatar)   # injects has_many :avatar (scoped to "avatar" collection)

    timestamps()
  end

  media_collections do
    collection :images, max_files: 20
    collection :documents, accepts: ~w(application/pdf text/plain)
    collection :avatar, single_file: true, fallback_url: "/images/default.png"
  end

  media_conversions do
    convert :thumb, width: 150, height: 150, fit: :cover
    convert :preview, width: 800, quality: 85
    convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
  end
end
```

### Function-based approach

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  schema "posts" do
    field :title, :string
    has_media()
    timestamps()
  end

  def media_collections do
    [
      collection(:images),
      collection(:documents, accepts: ~w(application/pdf)),
      collection(:avatar, single_file: true)
    ]
  end

  def media_conversions do
    [
      conversion(:thumb, width: 150, height: 150, fit: :cover),
      conversion(:preview, width: 800, quality: 85)
    ]
  end
end
```

The `has_media()` macro injects a polymorphic `has_many :media` association so you can use standard Ecto preloading:

```elixir
post = Repo.get!(Post, id) |> Repo.preload([:media, :images, :avatar])
```

Collection-scoped variants like `has_media(:images)` add a scoped `has_many` filtered by both model type and collection name.

## Add Media

```elixir
# From a file path
{:ok, media} =
  post
  |> PhxMediaLibrary.add("/path/to/image.jpg")
  |> PhxMediaLibrary.to_collection(:images)

# With custom filename and metadata
{:ok, media} =
  post
  |> PhxMediaLibrary.add(upload)
  |> PhxMediaLibrary.using_filename("custom-name.jpg")
  |> PhxMediaLibrary.with_custom_properties(%{"alt" => "My image"})
  |> PhxMediaLibrary.to_collection(:images)

# From a URL
{:ok, media} =
  post
  |> PhxMediaLibrary.add_from_url("https://example.com/image.jpg")
  |> PhxMediaLibrary.to_collection(:images)

# Bang version raises on error
media = PhxMediaLibrary.to_collection!(adder, :images)
```

## Retrieve Media

```elixir
# Get all media in a collection
PhxMediaLibrary.get_media(post, :images)

# Get the first media item
PhxMediaLibrary.get_first_media(post, :images)

# Get URLs
PhxMediaLibrary.get_first_media_url(post, :images)
PhxMediaLibrary.get_first_media_url(post, :images, :thumb)
PhxMediaLibrary.get_first_media_url(post, :avatar, fallback: "/default.jpg")

# Get URL for a specific media item
PhxMediaLibrary.url(media)
PhxMediaLibrary.url(media, :thumb)

# Composable Ecto queries
PhxMediaLibrary.media_query(post, :images)
|> where([m], m.mime_type == "image/png")
|> limit(5)
|> Repo.all()
```

## Delete Media

```elixir
# Delete a single media item (removes files from storage too)
PhxMediaLibrary.delete(media)

# Clear all media in a collection (batch-optimized, single DELETE query)
{:ok, count} = PhxMediaLibrary.clear_collection(post, :images)

# Clear all media for a model (batch-optimized)
{:ok, count} = PhxMediaLibrary.clear_media(post)
```

## Next Steps

- [Collections & Conversions](collections-and-conversions.md) — Validation rules, image processing, responsive images
- [LiveView Integration](liveview.md) — Drop-in upload and gallery components
- [Storage](storage.md) — Multiple backends, custom adapters
- [Error Handling](error-handling.md) — Tagged tuples, custom exceptions, MIME detection
- [Telemetry](telemetry.md) — Monitoring and observability events
- [Advanced Usage](advanced.md) — Reordering, mix tasks, view helpers, testing