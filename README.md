# PhxMediaLibrary

[![Hex.pm](https://img.shields.io/hexpm/v/phx_media_library.svg)](https://hex.pm/packages/phx_media_library)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/phx_media_library)
[![License](https://img.shields.io/hexpm/l/phx_media_library.svg)](https://github.com/mike-kostov/phoenix-media-library/blob/main/LICENSE)

Attach files to any Ecto schema, inspired by
[Spatie's Laravel Media Library](https://spatie.be/docs/laravel-medialibrary).

You declare collections and conversions next to your schema, pipe an upload
into a collection, and render it with a component. The library stores the
file under a safe name, makes thumbnails, WebP, AVIF and responsive sizes in
the background, and gives every image a tiny placeholder.

## Quick look

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
    collection :images, max_files: 20, max_size: 10_000_000, webp: true, avif: true, responsive: true
    collection :documents, accepts: ~w(application/pdf text/plain), file_naming: :random
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
{:ok, media} =
  post
  |> PhxMediaLibrary.add("/path/to/photo.jpg")
  |> PhxMediaLibrary.with_custom_properties(%{"alt" => "Red summer dress"})
  |> PhxMediaLibrary.to_collection(:images)

PhxMediaLibrary.get_media(post, :images)
PhxMediaLibrary.get_first_media_url(post, :images, :thumb)

PhxMediaLibrary.delete(media)
{:ok, count} = PhxMediaLibrary.clear_collection(post, :images)
```

### LiveView uploads

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
    case consume_media(socket, :images, socket.assigns.post, :images) do
      {:ok, saved} ->
        {:noreply, stream_media_items(socket, :media, saved)}

      {:error, {:partial, saved, failed}} ->
        {:noreply,
         socket
         |> stream_media_items(:media, saved)
         |> put_flash(:error, "#{length(failed)} file(s) could not be uploaded")}
    end
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

## Fast pages by default

The image components do the page-speed work for you:

```heex
<%!-- The hero: loads first, no lazy loading --%>
<.responsive_img media={@post.cover} priority class="w-full h-auto" />

<%!-- A product grid: lazy, and the browser picks the size for the slot --%>
<.responsive_img
  :for={product <- @products}
  media={product.photo}
  conversion={:preview}
  sizes="(max-width: 768px) 50vw, 25vw"
/>
```

- **Placeholders.** Every image gets a 32px blurred WebP of about 260
  bytes, set as its background until it loads. No JavaScript, no layout
  jump. `placeholder: :color` uses the average color instead.
- **No layout shift.** `width` and `height` come from the stored file, so
  the browser reserves the space.
- **The right size.** With `responsive: true`, `srcset` lists every
  variant, and lazy images default to `sizes="auto, 100vw"`, so supporting
  browsers measure the slot instead of assuming the full screen.
- **Small formats.** Conversions are WebP by default. `webp: true` also
  serves the original as WebP; `avif: true` adds an AVIF of the original
  and its sizes, which `<.picture>` and `<.responsive_img>` offer first,
  with WebP or the original as the fallback. A plain URL is never AVIF,
  since AI tools and most link previews can't read it.
- **Priority.** `priority` marks the page's main image `loading="eager"`
  and `fetchpriority="high"`; other images decode asynchronously.
- **Caching.** `cdn_url/2` adds a content fingerprint (`?vsn=…`) that
  `Plug.Static` answers with a one-year cache.

## Files named by the library

Uploaded filenames are never trusted. The library picks the stored name:
`posts_42_images_<uuid>.jpg` by default, a readable `summer-dress.jpg` with
`file_naming: :slug` (Cyrillic is transliterated), or a name that reveals
nothing with `:random`. The uploaded name is kept, and the library uses it
for alt text and as the name of downloads, `Лятна рокля.pdf` included.

## A doctor for your media

```bash
$ mix phx_media_library.doctor               # report only
$ mix phx_media_library.doctor --regenerate  # make missing thumbnails, WebP, AVIF, placeholders
$ mix phx_media_library.doctor --rename      # move older files to the naming scheme
$ mix phx_media_library.doctor --id <uuid>   # one media item
```

It finds media with no files left, missing derivatives, lost metadata,
checksum mismatches (`--deep`) and records whose parent is gone. Repairs
show their plan and ask first.

## Uploads straight to S3 or R2

`presigned_upload/3` signs a browser upload to S3, Cloudflare R2 or any
S3-compatible service, as a form POST or a PUT, whichever the provider
supports. `complete_external_upload/4` then reads the stored file and checks
its size and type against the collection before recording it. The
[storage guide](guides/storage.md#direct-uploads-to-s3) has a LiveView
uploader.

## Features

| Category | What you get |
|----------|-------------|
| **Schema integration** | Polymorphic `has_media()` macro, a DSL for collections and conversions |
| **Collections** | MIME validation, file count and size limits, pixel limits, single-file mode, fallback URLs |
| **Image conversions** | Resizes and crops, WebP by default (`format: :original` keeps the upload's format), responsive `srcset`; same-shape conversions share the original's variants. Optional: works without libvips |
| **Placeholders** | A 32px blurred WebP (or the average color) for every image, made in the background, shown by every image component |
| **AVIF** | Opt-in `avif: true`: an AVIF of each image and its sizes, offered first through `<picture>` with WebP or the original as the fallback |
| **WebP & HEIC** | Conversions are WebP; `webp: true` also transcodes raster and HEIC originals to WebP and serves them |
| **File naming** | `:semantic` (default), `:slug` or `:random` stored names; the uploaded name kept for alt text and downloads |
| **Metadata** | Dimensions, EXIF, format and type stored in a `metadata` JSON field |
| **Signed and download URLs** | Expiring URLs on disk and S3; downloads keep the uploaded name, with a UTF-8 `filename*` |
| **Remote URLs** | `add_from_url/3` with SSRF protection, streaming to disk, size and time limits |
| **Storage** | Local disk, S3 and S3-compatible services (Cloudflare R2, MinIO), in-memory for tests, or your own adapter |
| **Direct S3 uploads** | `presigned_upload/3` + `complete_external_upload/4`, POST or PUT per provider, limits checked on completion |
| **Streaming** | Files go to storage in 64 KB chunks, never whole in memory; downloads stream with `send_file` |
| **Async processing** | Task (default), Oban or inline; conversions and placeholders run in the background |
| **LiveView** | `<.media_upload>` and `<.media_gallery>` components, `LiveUpload` helpers with partial-failure results |
| **View helpers** | `<.media_img>`, `<.responsive_img>`, `<.picture>` and `<.media_figure>` (image with caption) |
| **Security** | Content-based MIME detection, SHA-256 checksums, safe stored names, SVGs served sandboxed (`Plug.StaticHeaders`) |
| **Doctor** | `mix phx_media_library.doctor` checks files, metadata, names and checksums, and repairs what it can |
| **Soft deletes** | Opt-in `deleted_at` with `restore/1`, `purge_trashed/2` and a purge task |
| **Batch ops** | `clear_collection/2`, `clear_media/1`, `reorder/3`, `move_to/2` |
| **Telemetry** | `:start`/`:stop`/`:exception` spans for add, delete, conversion, storage, batch, download |
| **Errors** | Tagged tuples and structured exceptions (`Error`, `StorageError`, `ValidationError`) |
| **Queries** | `media_query/2` returns a composable `Ecto.Query` |

## Installation

```elixir
def deps do
  [
    {:phx_media_library, "~> 0.9"},

    # Optional: image processing (requires libvips)
    {:image, "~> 0.54"},

    # Optional: S3 storage
    {:ex_aws, "~> 2.5"},
    {:ex_aws_s3, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},

    # Optional: async processing with Oban
    {:oban, "~> 2.18"}
  ]
end
```

```elixir
# config/config.exs
config :phx_media_library,
  repo: MyApp.Repo,
  default_disk: :local,

  # The column type of your models' primary keys.
  # :binary_id  UUID (default, keeps existing installs working)
  # :integer    bigint (integer primary keys)
  # :string     varchar (any primary key type; recommended for new apps)
  mediable_id_type: :string,

  disks: [
    local: [
      adapter: PhxMediaLibrary.Storage.Disk,
      root: "priv/static/uploads",
      base_url: "/uploads"
    ]
  ]
```

```bash
# For integer primary keys, pass --id-type to generate the right column:
mix phx_media_library.install --id-type integer
mix ecto.migrate
```

`mediable_id_type` sets the column type of the polymorphic foreign key. The
default stays `:binary_id` (UUID) so existing installs keep working;
`:string` works with any primary key type. Set it explicitly and a future
change of default won't affect you.

The `:image` dependency is optional. Without it the library stores files;
conversions, WebP, AVIF and placeholders need it.

## Guides

| Guide | Covers |
|-------|--------|
| **[Getting Started](guides/getting-started.md)** | Installation, configuration, schema setup, adding and retrieving media |
| **[Collections & Conversions](guides/collections-and-conversions.md)** | Validation, image processing, WebP, AVIF, placeholders, responsive images |
| **[LiveView Integration](guides/liveview.md)** | Upload and gallery components, LiveUpload helpers, events, view helpers |
| **[Storage](guides/storage.md)** | Local disk, S3 and R2, direct uploads, signed URLs, caching, custom adapters |
| **[Error Handling](guides/error-handling.md)** | Tagged tuples, custom exceptions, MIME detection |
| **[Telemetry](guides/telemetry.md)** | Events reference, attaching handlers, metrics examples |
| **[Advanced Usage](guides/advanced.md)** | Reordering, mix tasks, testing strategies |
| **[Multi-tenant](guides/multi-tenant.md)** | Per-tenant storage paths and scoping |
| **[Upgrading to 0.9](guides/upgrading-to-0.9.md)** | Every behaviour change, and how to keep the old one |

Full API documentation is on [HexDocs](https://hexdocs.pm/phx_media_library).

## Contributing

Contributions are welcome. Please open a pull request.

The tests need Postgres on `localhost` (user and password `postgres`), and
podman or Docker for the S3 tests. Those run against a
[Ministack](https://hub.docker.com/r/ministackorg/ministack) container that
the first `mix test` starts and later runs reuse; without podman or Docker
they are skipped. Run `mix precommit` before opening a pull request.

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a pull request

## License

MIT. See the [LICENSE](https://github.com/mike-kostov/phoenix-media-library/blob/main/LICENSE) file.

## Acknowledgments

Inspired by [Spatie's Laravel Media Library](https://spatie.be/docs/laravel-medialibrary).
