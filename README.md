# PhxMediaLibrary

[![Hex.pm](https://img.shields.io/hexpm/v/phx_media_library.svg)](https://hex.pm/packages/phx_media_library)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/phx_media_library)
[![License](https://img.shields.io/hexpm/l/phx_media_library.svg)](https://github.com/mike-kostov/phx_media_library/blob/main/LICENSE)

A robust, Ecto-backed media management library for Elixir and Phoenix, inspired by [Spatie's Laravel Media Library](https://spatie.be/docs/laravel-medialibrary).

## Features

- **Associate files with Ecto schemas** — Polymorphic media associations via `has_media()` macro
- **Declarative DSL** — Define collections and conversions with a clean macro syntax
- **Collections** — Organize media into named collections with MIME validation, file limits, and single-file mode
- **Image conversions** — Generate thumbnails, previews, and custom sizes (optional — works without libvips)
- **Responsive images** — Automatic srcset generation for optimal loading
- **Multiple storage backends** — Local filesystem, S3, in-memory (for tests), or custom adapters
- **Async processing** — Background conversion processing with Task (default) or Oban
- **LiveView components** — Drop-in `<.media_upload>` and `<.media_gallery>` components that eliminate upload boilerplate
- **LiveUpload helpers** — `use PhxMediaLibrary.LiveUpload` for collection-aware uploads with one line
- **Checksum integrity** — SHA-256 computed on upload, verifiable at any time
- **Composable queries** — `media_query/2` returns an `Ecto.Query` for further composition
- **Phoenix view helpers** — `<.media_img>`, `<.responsive_img>`, and `<.picture>` components

## Installation

Add `phx_media_library` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phx_media_library, "~> 0.2.0"},

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

PhxMediaLibrary supports two styles for defining collections and conversions. You can use either — or mix them.

#### Declarative DSL (recommended)

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

#### Function-based approach

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

### 3. Add media to your models

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

### 4. Retrieve media

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

## LiveView Components

PhxMediaLibrary ships with drop-in LiveView components that eliminate 150+ lines of upload boilerplate.

### Setup

Add to your `my_app_web.ex`:

```elixir
defp html_helpers do
  quote do
    # ... existing imports
    import PhxMediaLibrary.Components
    import PhxMediaLibrary.ViewHelpers
  end
end
```

### Upload + Gallery in a LiveView

```elixir
defmodule MyAppWeb.PostLive.Edit do
  use MyAppWeb, :live_view
  use PhxMediaLibrary.LiveUpload

  def mount(%{"id" => id}, _session, socket) do
    post = Posts.get_post!(id)

    {:ok,
     socket
     |> assign(:post, post)
     |> allow_media_upload(:images, model: post, collection: :images)
     |> stream_existing_media(:media, post, :images)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_media", _params, socket) do
    case consume_media(socket, :images, socket.assigns.post, :images, notify: self()) do
      {:ok, media_items} ->
        {:noreply,
         socket
         |> stream_media_items(:media, media_items)
         |> put_flash(:info, "Uploaded #{length(media_items)} file(s)")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_media", %{"id" => id}, socket) do
    case delete_media_by_id(id, notify: self()) do
      :ok -> {:noreply, stream_delete_by_dom_id(socket, :media, "media-#{id}")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  # React to media lifecycle events
  def handle_info({:media_added, media_items}, socket) do
    {:noreply, assign(socket, :media_count, length(media_items))}
  end

  def handle_info({:media_removed, _media}, socket) do
    {:noreply, socket}
  end
end
```

### Template

```heex
<form phx-change="validate" phx-submit="save_media">
  <.media_upload
    upload={@uploads.images}
    id="post-images-upload"
    label="Upload Images"
    sublabel="JPG, PNG, WebP up to 10MB"
  />

  <button type="submit">Upload</button>
</form>

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

### `<.media_upload>` Features

- Drag-and-drop with visual feedback (`.MediaDropZone` JS hook)
- Live image previews via `<.live_img_preview>`
- Upload progress bars per entry
- Per-entry error display and cancel buttons
- Full-size and compact layouts
- Dark mode support
- Fully customizable via attrs, slots, and CSS classes

### `<.media_gallery>` Features

- Stream-powered grid (2–6 configurable columns)
- Image thumbnails with delete-on-hover
- Document type icons (PDF, spreadsheet, archive, etc.)
- `:item` and `:empty` slots for custom rendering

### `<.media_upload_button>`

A compact inline variant for embedding upload triggers within forms or tight layouts.

### `PhxMediaLibrary.LiveUpload` Helpers

`use PhxMediaLibrary.LiveUpload` imports these functions into your LiveView:

| Function | Purpose |
|----------|---------|
| `allow_media_upload/3` | Wraps `allow_upload/3` with collection-aware defaults (accept types, max entries, max file size) |
| `consume_media/5` | Consumes uploads and persists via `PhxMediaLibrary.add/2 \|> to_collection/2` |
| `stream_existing_media/4` | Loads existing media into a LiveView stream |
| `stream_media_items/3` | Inserts newly created media into a stream |
| `delete_media_by_id/2` | Deletes a media record and its files |
| `media_upload_errors/1` | Human-readable error strings for an upload |
| `media_entry_errors/2` | Human-readable error strings for an entry |
| `has_upload_entries?/1` | Whether the upload has any entries |
| `image_entry?/1` | Whether an entry is an image (for conditional previews) |
| `translate_upload_error/1` | Extensible error atom → string translation |

### Event Notifications

Both `consume_media/5` and `delete_media_by_id/2` accept a `:notify` option. When set to a pid (e.g. `self()`), lifecycle messages are sent to that process:

- `{:media_added, [Media.t()]}` — after successful upload
- `{:media_error, reason}` — when upload fails
- `{:media_removed, Media.t()}` — after successful deletion

Handle them in your LiveView via `handle_info/2`.

## Collections

Collections organize media and apply validation rules.

```elixir
media_collections do
  # Basic collection
  collection :images

  # MIME type validation
  collection :documents, accepts: ~w(application/pdf application/msword)

  # Single file only (replaces existing on new upload)
  collection :avatar, single_file: true

  # Limit number of files (oldest excess is removed)
  collection :gallery, max_files: 10

  # Custom storage disk
  collection :backups, disk: :s3

  # Fallback URL when collection is empty
  collection :profile_photo, single_file: true, fallback_url: "/images/default-avatar.png"
end
```

## Conversions

Conversions automatically generate derived images when media is added. Requires the `:image` dependency.

```elixir
media_conversions do
  # Simple resize
  convert :thumb, width: 150, height: 150

  # Resize with fit mode
  convert :square, width: 300, height: 300, fit: :cover

  # Width only (maintains aspect ratio)
  convert :preview, width: 800

  # With quality setting
  convert :optimized, width: 1200, quality: 80

  # Convert format
  convert :webp_thumb, width: 150, format: :webp

  # Only for specific collections
  convert :banner, width: 1200, collections: [:images, :gallery]
end
```

### Fit Options

| Mode | Behaviour |
|------|-----------|
| `:contain` | Fit within dimensions, maintaining aspect ratio |
| `:cover` | Cover dimensions, cropping if necessary |
| `:fill` | Stretch to fill dimensions exactly |
| `:crop` | Crop to exact dimensions from center |

## Checksum & Integrity Verification

SHA-256 checksums are computed automatically during upload and stored alongside each media record.

```elixir
# Verify a file hasn't been tampered with or corrupted
case PhxMediaLibrary.verify_integrity(media) do
  :ok -> IO.puts("File is intact")
  {:error, :checksum_mismatch} -> IO.puts("File has been corrupted!")
  {:error, :no_checksum} -> IO.puts("No checksum stored for this media")
end
```

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
# => "uploads/posts/1/responsive/image-320.jpg 320w, ..."
```

## View Helpers

For standard (non-LiveView) templates, PhxMediaLibrary provides rendering components.

### Simple Image

```heex
<.media_img media={@media} class="rounded-lg" />

<.media_img media={@media} conversion={:thumb} alt="Product image" />
```

### Responsive Image

```heex
<.responsive_img
  media={@media}
  sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 800px"
  class="w-full h-auto"
  alt="Hero image"
/>
```

### Picture Element (Art Direction)

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

## Mix Tasks

### Install

```bash
mix phx_media_library.install
```

### Regenerate Conversions

```bash
mix phx_media_library.regenerate --conversion thumb
mix phx_media_library.regenerate --collection images
mix phx_media_library.regenerate --dry-run
```

### Regenerate Responsive Images

```bash
mix phx_media_library.regenerate_responsive
mix phx_media_library.regenerate_responsive --collection images
```

### Clean Orphaned Files

```bash
# Dry run — see what would be deleted
mix phx_media_library.clean

# Actually delete
mix phx_media_library.clean --force
```

### Generate Custom Migration

```bash
mix phx_media_library.gen.migration add_blurhash_field
```

## Deleting Media

```elixir
# Delete a single media item (removes files from storage too)
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
    # File type not accepted by collection
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

Don't forget to start the memory storage agent in your `test_helper.exs`:

```elixir
{:ok, _} = PhxMediaLibrary.Storage.Memory.start_link()
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Inspired by [Spatie's Laravel Media Library](https://spatie.be/docs/laravel-medialibrary), bringing its excellent developer experience to the Elixir ecosystem.