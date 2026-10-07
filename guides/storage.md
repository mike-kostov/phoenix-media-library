# Storage

PhxMediaLibrary abstracts file storage behind behaviours, so you can swap
backends without changing application code. It ships with local
disk, Amazon S3, and an in-memory adapter for tests.

## Configuring storage

You configure storage with **disks**, named backend configurations. Set a
default disk and define one or more named disks:

```elixir
# config/config.exs
config :phx_media_library,
  default_disk: :local,
  disks: [
    local: [
      adapter: PhxMediaLibrary.Storage.Disk,
      root: "priv/static/uploads",
      base_url: "/uploads"
    ]
  ]
```

### Local disk

The default adapter. It stores files on the local filesystem.

| Option | Required | Description |
|--------|----------|-------------|
| `:root` | yes | Filesystem directory for stored files |
| `:base_url` | yes | URL prefix for generating public URLs |

```elixir
disks: [
  local: [
    adapter: PhxMediaLibrary.Storage.Disk,
    root: "priv/static/uploads",
    base_url: "/uploads"
  ]
]
```

Serve the files from your endpoint with their own `Plug.Static`, placed
before the default one. Phoenix's default `static_paths` don't include
`uploads`, so without this the URLs return 404:

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Static,
  at: "/uploads",
  from: {:my_app, "priv/static/uploads"},
  headers: {PhxMediaLibrary.Plug.StaticHeaders, :headers, []}
```

The `headers` option serves SVG uploads sandboxed. An SVG can contain
JavaScript; through an `<img>` tag it never runs, but opening the file's URL
directly would run it on your domain. With these headers it doesn't. See
`PhxMediaLibrary.Plug.StaticHeaders`.

### Amazon S3 and S3-compatible services

Requires the optional `:ex_aws`, `:ex_aws_s3`, and `:sweet_xml` dependencies.
The same adapter works with AWS, Cloudflare R2 and any S3-compatible
service; `provider:` picks the right defaults for each.

| Option | Required | Description |
|--------|----------|-------------|
| `:bucket` | yes | Bucket name |
| `:provider` | no | `:aws` (default), `:r2` or `:generic` |
| `:region` | AWS | AWS region (e.g. `"us-east-1"`); `"auto"` on R2 |
| `:account_id` | R2 | Cloudflare account ID; the endpoint is built from it |
| `:endpoint` | `:generic` | API URL, e.g. `"https://s3.example.com"` |
| `:base_url` | R2 | Public URL base: a CDN or custom domain |
| `:addressing` | no | `:path` (default) or `:virtual_host` |
| `:direct_upload` | no | `:post` (default on AWS) or `:put` (default elsewhere); see Direct uploads |
| `:acl` | no | ACL sent with uploads (default: none, the bucket's settings apply) |
| `:cache_control` | no | `Cache-Control` stored with uploads (see Caching) |

```elixir
disks: [
  # AWS
  s3: [
    adapter: PhxMediaLibrary.Storage.S3,
    bucket: "my-media-bucket",
    region: "us-east-1"
  ],
  # Cloudflare R2
  r2: [
    adapter: PhxMediaLibrary.Storage.S3,
    provider: :r2,
    account_id: System.get_env("R2_ACCOUNT_ID"),
    bucket: "media",
    base_url: "https://media.example.com",
    access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY")
  ],
  # Any other S3-compatible service
  minio: [
    adapter: PhxMediaLibrary.Storage.S3,
    provider: :generic,
    endpoint: "https://s3.example.com",
    bucket: "media"
  ]
]

# ExAws credentials (never hard-code these)
config :ex_aws,
  access_key_id: {:system, "AWS_ACCESS_KEY_ID"},
  secret_access_key: {:system, "AWS_SECRET_ACCESS_KEY"}
```

Public URLs use `:base_url` when set, otherwise the endpoint (or
`amazonaws.com` on AWS). R2 serves public files only from a custom domain
or an r2.dev URL, so an `:r2` disk needs `:base_url` for public URLs;
signed URLs work without it. A disk option always wins over its provider's
default, so a service with its own quirks works as `:generic` plus the
options it needs.

### In-memory (testing)

Stores files in a process-backed map. Tests run fast and isolated, with no
filesystem side effects.

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

Start the memory agent in your `test_helper.exs`:

```elixir
{:ok, _} = PhxMediaLibrary.Storage.Memory.start_link()
```

## Signed and download URLs

`PhxMediaLibrary.signed_url/3` gives an expiring URL: an AWS presigned URL
on S3, or an HMAC-signed one on disk, served by
`PhxMediaLibrary.Plug.MediaDownload`. `PhxMediaLibrary.download_url/3`
makes the browser save the file instead of showing it, under the name it
was uploaded with:

```elixir
# router.ex
forward "/media", PhxMediaLibrary.Plug.MediaDownload, disk: :local

# config: the disk needs download_base_url: "/media" and secret_key_base
PhxMediaLibrary.download_url(media, nil, signed: true, expires_in: 300)
#=> "/media/posts/42/…/posts_42_documents_….pdf?dl=1&exp=…&name=…&sign=…"
```

The download is named `metadata["original_file_name"]` (pass `filename:`
to choose another), sent as an ASCII `filename` plus the exact UTF-8
`filename*`, so `Лятна рокля.pdf` arrives as itself. On disk the name is
part of the signature; unsigned download URLs use the stored name, since
anyone could change it.

## Caching

Media files rarely change, so browsers and CDNs can keep them for a long
time, as long as the URL changes when the file does. `cache_bust: true` adds
a fingerprint of the file's checksum:

```elixir
PhxMediaLibrary.url(media, :thumb, cache_bust: true)
#=> "/uploads/posts/42/…/posts_42_images_…_thumb.jpg?vsn=a1b2c3d4"
```

- **Local disk:** `Plug.Static` already answers `?vsn=` requests with
  `Cache-Control: public, max-age=31536000` (its
  `cache_control_for_vsn_requests` option), so nothing else is needed.
- **S3:** set `cache_control:` on the disk so every upload carries the
  header:

  ```elixir
  s3: [
    adapter: PhxMediaLibrary.Storage.S3,
    bucket: "my-bucket",
    cache_control: "public, max-age=31536000, immutable"
  ]
  ```

The fingerprint comes from the original's checksum. Files regenerated in
place (`mix phx_media_library.doctor --rebuild`) keep their URL, so purge
your CDN after a rebuild.

## Direct uploads to S3

Large files can go from the browser straight to S3 without passing through
your server. The server signs the upload, the browser sends the file, and
the server records it afterwards.

```elixir
{:ok, upload} =
  PhxMediaLibrary.presigned_upload(post, :videos,
    filename: "launch.mp4",
    content_type: "video/mp4",
    size: 48_000_000
  )

upload.method   #=> :post or :put
upload.url      #=> where the browser sends the file
upload.fields   #=> form fields, for :post
upload.headers  #=> headers, for :put
upload.key      #=> pass to complete_external_upload/4
```

The method comes from the disk's `direct_upload:` setting:

- **`:post`** (default on AWS): a `multipart/form-data` form with every
  entry of `fields` and the file last. The fields carry a signed policy,
  so S3 itself rejects a different key, a size over the collection's
  `max_size` (or `:max_size`), or another content type.
- **`:put`** (default on R2 and `:generic`; R2 and Backblaze B2 have no
  form uploads): the file as the request body, with every entry of
  `headers`. The signature covers the key and the content type. A PUT
  can't limit the size, so a declared `:size` over the limit is refused
  before signing, and completion checks the real size.

With LiveView external uploads, sign each entry and pass the result as its
meta:

```elixir
allow_upload(socket, :videos, accept: ~w(.mp4), external: &presign_entry/2)

defp presign_entry(entry, socket) do
  case PhxMediaLibrary.presigned_upload(socket.assigns.post, :videos,
         filename: entry.client_name,
         content_type: entry.client_type,
         size: entry.client_size
       ) do
    {:ok, upload} -> {:ok, Map.put(upload, :uploader, "S3"), socket}
    {:error, reason} -> {:error, %{reason: inspect(reason)}, socket}
  end
end
```

This uploader in `app.js` handles both methods:

```javascript
let Uploaders = {}

Uploaders.S3 = function (entries, onViewError) {
  entries.forEach(entry => {
    let {method, url, fields, headers} = entry.meta
    let xhr = new XMLHttpRequest()
    onViewError(() => xhr.abort())
    xhr.onload = () => (xhr.status >= 200 && xhr.status < 300 ? entry.progress(100) : entry.error())
    xhr.onerror = () => entry.error()
    xhr.upload.addEventListener("progress", event => {
      if (event.lengthComputable) {
        let percent = Math.round((event.loaded / event.total) * 100)
        if (percent < 100) entry.progress(percent)
      }
    })

    xhr.open(method.toUpperCase(), url, true)

    if (method === "post") {
      let formData = new FormData()
      Object.entries(fields).forEach(([key, value]) => formData.append(key, value))
      formData.append("file", entry.file)
      xhr.send(formData)
    } else {
      Object.entries(headers).forEach(([key, value]) => xhr.setRequestHeader(key, value))
      xhr.send(entry.file)
    }
  })
}

let liveSocket = new LiveSocket("/live", Socket, {uploaders: Uploaders, params: {_csrf_token: csrfToken}})
```

The bucket must allow your site's origin in its CORS rules, for the method
the disk uses.

When the upload has finished, create the media record:

```elixir
{:ok, media} =
  PhxMediaLibrary.complete_external_upload(post, :videos, upload.key, filename: "launch.mp4")
```

The size and the content type are read from the stored object, never taken
from the client, and checked against the collection like any upload. An
object that fails is deleted and the call returns `{:error, reason}`; a
missing one returns `{:error, :not_found}`.

Before 0.9 the upload was a presigned `PUT` returned by
`presigned_upload_url/3`, removed in 0.10. On AWS disks a client that
still sends a `PUT` gets an error from S3: switch it to the uploader above,
or set `direct_upload: :put` on the disk and send the signed
`content-type`.

## Per-collection disk override

Individual collections can use a different disk than the default:

```elixir
media_collections do
  collection :images                       # uses default_disk
  collection :backups, disk: :s3           # uses the :s3 disk
  collection :temp_files, disk: :local     # explicit local
end
```

## Multiple disks

You can define as many disks as you need, for example a local disk for
development and S3 for production:

```elixir
# config/config.exs
config :phx_media_library,
  default_disk: :local,
  disks: [
    local: [
      adapter: PhxMediaLibrary.Storage.Disk,
      root: "priv/static/uploads",
      base_url: "/uploads"
    ],
    s3: [
      adapter: PhxMediaLibrary.Storage.S3,
      bucket: "my-bucket",
      region: "us-east-1"
    ]
  ]

# config/prod.exs: override the default in production
config :phx_media_library,
  default_disk: :s3
```

## Custom storage adapters

Implement the `PhxMediaLibrary.Storage` behaviour to add your own backend
(e.g. Google Cloud Storage, Azure Blob, SFTP):

```elixir
defmodule MyApp.Storage.CustomAdapter do
  @behaviour PhxMediaLibrary.Storage

  @impl true
  def put(path, content, opts) do
    # Store binary content at path
    # Return :ok or {:error, reason}
    :ok
  end

  @impl true
  def get(path, opts) do
    # Return {:ok, binary} or {:error, reason}
    {:ok, <<>>}
  end

  @impl true
  def delete(path, opts) do
    # Return :ok or {:error, reason}
    :ok
  end

  @impl true
  def exists?(path, opts) do
    # Return boolean
    true
  end

  @impl true
  def url(path, opts) do
    # Return a public URL string; url_path/1 percent-encodes each segment
    "https://my-cdn.com/" <> PhxMediaLibrary.Storage.url_path(path)
  end
end
```

Then register it as a disk:

```elixir
config :phx_media_library,
  disks: [
    custom: [
      adapter: MyApp.Storage.CustomAdapter,
      # Any adapter-specific options go here and are passed as `opts`
    ]
  ]
```

### Behaviour callbacks

| Callback | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `put/3` | `(path, content, opts)` | `:ok \| {:error, reason}` | Store binary content at path |
| `get/2` | `(path, opts)` | `{:ok, binary} \| {:error, reason}` | Retrieve file content |
| `delete/2` | `(path, opts)` | `:ok \| {:error, reason}` | Remove a file |
| `exists?/2` | `(path, opts)` | `boolean()` | Check if a file exists |
| `url/2` | `(path, opts)` | `String.t()` | Generate a public URL |

Optional callbacks: `path/2` (a local filesystem path), `stat/3` (size and
first bytes without reading the whole file) and `presigned_upload/3`
(signed direct uploads). See `PhxMediaLibrary.Storage` for their specs.

The `opts` map contains the disk configuration options (e.g. `:root`,
`:base_url`, `:bucket`) so your adapter can read them at runtime without
relying on global config.

## Path structure

Each media item gets a folder of its own. With the default path generator
and file naming, a photo in a WebP collection with responsive variants is
stored as:

```
posts/42/<uuid>/posts_42_images_<uuid>.jpg                       original
posts/42/<uuid>/posts_42_images_<uuid>.webp                      served WebP (.avif beside it)
posts/42/<uuid>/posts_42_images_<uuid>_thumb.webp                conversion
posts/42/<uuid>/responsive/posts_42_images_<uuid>_320w.webp      variant of the original
posts/42/<uuid>/responsive/posts_42_images_<uuid>_thumb_320w.webp  variant of a conversion
```

That is `{mediable_type}/{mediable_id}/{uuid}/{file_name}`. Conversions add
`_{name}` and carry their format's extension; variants live in
`responsive/` and add `_{width}w`. Other layouts come with the
`PathGenerator.Flat`, `PathGenerator.DateBased` and `PathGenerator.Tenant`
generators, or your own.

The library chooses the stored name (see `file_naming:` in the collections
guide); the uploaded name is kept in `metadata["original_file_name"]`.

## Telemetry

All storage operations emit telemetry events under the
`[:phx_media_library, :storage, ...]` prefix. See the
[Telemetry guide](telemetry.md) for details on attaching handlers to monitor
storage performance and errors.