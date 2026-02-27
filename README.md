# PhxMediaLibrary

[![Hex.pm](https://img.shields.io/hexpm/v/phx_media_library.svg)](https://hex.pm/packages/phx_media_library)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/phx_media_library)
[![License](https://img.shields.io/hexpm/l/phx_media_library.svg)](https://github.com/mike-kostov/phx_media_library/blob/main/LICENSE)

A robust, Ecto-backed media management library for Elixir and Phoenix, inspired by [Spatie's Laravel Media Library](https://spatie.be/docs/laravel-medialibrary).

Associate files with any Ecto schema using a fluent, composable API — with
collections, image conversions, LiveView components, and multiple storage
backends out of the box.

## Quick Look

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  schema "posts" do
    field :title, :string

    has_media()          # all media for this model
    has_media(:images)   # scoped to "images" collection
    has_media(:avatar)   # scoped to "avatar" collection

    timestamps()
  end

  media_collections do
    collection :images, max_files: 20, max_size: 10_000_000
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

```elixir
# Add media with a fluent pipeline
{:ok, media} =
  post
  |> PhxMediaLibrary.add("/path/to/photo.jpg")
  |> PhxMediaLibrary.using_filename("hero.jpg")
  |> PhxMediaLibrary.with_custom_properties(%{"alt" => "Hero image"})
  |> PhxMediaLibrary.to_collection(:images)

# Retrieve
PhxMediaLibrary.get_media(post, :images)
PhxMediaLibrary.get_first_media_url(post, :images, :thumb)

# Delete
PhxMediaLibrary.delete(media)
{:ok, count} = PhxMediaLibrary.clear_collection(post, :images)
```

### LiveView — One-Line Uploads

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

  def handle_event("save_media", _params, socket) do
    {:ok, media_items} = consume_media(socket, :images, socket.assigns.post, :images)
    {:noreply, stream_media_items(socket, :media, media_items)}
  end
end
```

```heex
<form phx-change="validate" phx-submit="save_media">
  <.media_upload upload={@uploads.images} id="post-images" />
  <button type="submit">Upload</button>
</form>

<.media_gallery media={@streams.media} id="gallery">
  <:item :let={{_id, media}}>
    <.media_img media={media} conversion={:thumb} class="rounded-lg" />
  </:item>
</.media_gallery>
```

## Features

| Category | What you get |
|----------|-------------|
| **Schema integration** | Polymorphic `has_media()` macro, declarative DSL for collections & conversions |
| **Collections** | MIME validation, file limits, size limits, single-file mode, fallback URLs |
| **Image conversions** | Thumbnails, resizes, format conversion, responsive srcset — optional, works without libvips |
| **Metadata extraction** | Auto-extract dimensions, EXIF, format, type classification; stored in `metadata` JSON field |
| **Remote URLs** | `add_from_url/3` with scheme validation, custom headers, timeout, download telemetry |
| **Storage** | Local disk, S3, in-memory (tests), or custom adapters via `PhxMediaLibrary.Storage` behaviour |
| **Streaming uploads** | Files streamed to storage in 64 KB chunks — never loaded entirely into memory |
| **Direct S3 uploads** | `presigned_upload_url/3` + `complete_external_upload/4` for client-to-S3 without proxying |
| **Soft deletes** | Opt-in `deleted_at` with `restore/1`, `purge_trashed/2`, query scoping, and purge Mix task |
| **Async processing** | Task (default) or Oban adapter with persistence, retries, and `process_sync/2` |
| **LiveView** | Drop-in `<.media_upload>` and `<.media_gallery>` components, `LiveUpload` helpers |
| **Security** | Content-based MIME detection (50+ formats via magic bytes), SHA-256 checksums |
| **Batch ops** | `clear_collection/2`, `clear_media/1`, `reorder/3`, `move_to/2` |
| **Telemetry** | `:start`/`:stop`/`:exception` spans for add, delete, conversion, storage, batch, download |
| **Errors** | Tagged tuples + structured exceptions (`Error`, `StorageError`, `ValidationError`) |
| **Queries** | `media_query/2` returns composable `Ecto.Query` |
| **View helpers** | `<.media_img>`, `<.responsive_img>`, `<.picture>` components |
| **Mix tasks** | Install, regenerate conversions, clean orphans, purge deleted, generate migrations |

## Installation

```elixir
def deps do
  [
    {:phx_media_library, "~> 0.5.0"},

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

```elixir
# config/config.exs
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

```bash
mix phx_media_library.install
mix ecto.migrate
```

> **Note:** The `:image` dependency is **optional**. PhxMediaLibrary works for
> file storage without it. Image conversions require `:image` to be installed.

## Guides

Detailed documentation is organized into focused guides:

| Guide | Covers |
|-------|--------|
| **[Getting Started](guides/getting-started.md)** | Installation, configuration, schema setup, adding & retrieving media |
| **[Collections & Conversions](guides/collections-and-conversions.md)** | Validation rules, image processing, responsive images, checksums |
| **[LiveView Integration](guides/liveview.md)** | Upload & gallery components, LiveUpload helpers, event notifications, view helpers |
| **[Storage](guides/storage.md)** | Local disk, S3, in-memory, custom adapters, path conventions |
| **[Error Handling](guides/error-handling.md)** | Tagged tuples, custom exceptions, MIME detection |
| **[Telemetry](guides/telemetry.md)** | Events reference, attaching handlers, metrics examples |
| **[Advanced Usage](guides/advanced.md)** | Reordering, mix tasks, testing strategies |

Full API documentation is available on [HexDocs](https://hexdocs.pm/phx_media_library).

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