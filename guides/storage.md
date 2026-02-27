# Storage

PhxMediaLibrary abstracts file storage behind behaviours, so you can swap
backends without changing application code. Out of the box it ships with local
disk, Amazon S3, and an in-memory adapter for tests.

## Configuring Storage

Storage is configured via **disks** — named backend configurations. Set a
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

### Local Disk

The default adapter. Files are stored on the local filesystem.

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

### Amazon S3

Requires the optional `:ex_aws`, `:ex_aws_s3`, and `:sweet_xml` dependencies.

| Option | Required | Description |
|--------|----------|-------------|
| `:bucket` | yes | S3 bucket name |
| `:region` | yes | AWS region (e.g. `"us-east-1"`) |

```elixir
disks: [
  s3: [
    adapter: PhxMediaLibrary.Storage.S3,
    bucket: "my-media-bucket",
    region: "us-east-1"
  ]
]

# ExAws credentials (never hard-code these)
config :ex_aws,
  access_key_id: {:system, "AWS_ACCESS_KEY_ID"},
  secret_access_key: {:system, "AWS_SECRET_ACCESS_KEY"}
```

### In-Memory (Testing)

Stores files in a process-backed map. Perfect for fast, isolated tests with no
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

## Per-Collection Disk Override

Individual collections can use a different disk than the default:

```elixir
media_collections do
  collection :images                       # uses default_disk
  collection :backups, disk: :s3           # uses the :s3 disk
  collection :temp_files, disk: :local     # explicit local
end
```

## Multiple Disks

You can define as many disks as you need — for example, a local disk for
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

# config/prod.exs — override the default in production
config :phx_media_library,
  default_disk: :s3
```

## Custom Storage Adapters

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
    # Return a public URL string
    "https://my-cdn.com/#{path}"
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

### Behaviour Callbacks

| Callback | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `put/3` | `(path, content, opts)` | `:ok \| {:error, reason}` | Store binary content at path |
| `get/2` | `(path, opts)` | `{:ok, binary} \| {:error, reason}` | Retrieve file content |
| `delete/2` | `(path, opts)` | `:ok \| {:error, reason}` | Remove a file |
| `exists?/2` | `(path, opts)` | `boolean()` | Check if a file exists |
| `url/2` | `(path, opts)` | `String.t()` | Generate a public URL |

The `opts` map contains the disk configuration options (e.g. `:root`,
`:base_url`, `:bucket`) so your adapter can read them at runtime without
relying on global config.

## Path Structure

PhxMediaLibrary stores files using a predictable path convention:

```
{collection}/{mediable_id}/{filename}
{collection}/{mediable_id}/conversions/{conversion_name}/{filename}
{collection}/{mediable_id}/responsive/{filename}-{width}.{ext}
```

For example:

```
images/42/photo.jpg
images/42/conversions/thumb/photo.jpg
images/42/responsive/photo-320.jpg
```

Original filenames provided by users are sanitized for safety. The original
name is preserved in the database `file_name` field for display purposes.

## Telemetry

All storage operations emit telemetry events under the
`[:phx_media_library, :storage, ...]` prefix. See the
[Telemetry guide](telemetry.md) for details on attaching handlers to monitor
storage performance and errors.