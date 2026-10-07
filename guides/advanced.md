# Advanced usage

This guide covers reordering, mix tasks, and testing strategies.

## Reordering media

Media items within a collection have an `order_column` that controls their
display order. PhxMediaLibrary provides two functions for managing order.

### Reorder by ID list

Set the exact order for all items in a collection by passing an ordered list of
IDs. This runs in a single database transaction:

```elixir
# Set explicit order: id3 first, id1 second, id2 third
{:ok, count} = PhxMediaLibrary.reorder(post, :images, [id3, id1, id2])
```

IDs not present in the collection are silently ignored. Items whose IDs are not
in the provided list keep their current order but are shifted after the
explicitly ordered items.

### Move a single item

Move one media item to a specific 1-based position within its collection:

```elixir
{:ok, updated_media} = PhxMediaLibrary.move_to(media, 1)   # move to first
{:ok, updated_media} = PhxMediaLibrary.move_to(media, 3)   # move to third
```

The position is clamped to the valid range. Passing a position larger than the
collection size moves the item to the end.

### Drag-and-drop reordering

A common pattern for LiveView drag-and-drop:

```elixir
def handle_event("reorder", %{"ids" => ordered_ids}, socket) do
  case PhxMediaLibrary.reorder(socket.assigns.post, :images, ordered_ids) do
    {:ok, _count} ->
      {:noreply, stream_existing_media(socket, :media, socket.assigns.post, :images)}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Reorder failed: #{inspect(reason)}")}
  end
end
```

## Deleting media

```elixir
# Delete a single media item (removes files from storage too)
PhxMediaLibrary.delete(media)

# Clear all media in a collection (batch-optimized, single DELETE query)
{:ok, count} = PhxMediaLibrary.clear_collection(post, :images)

# Clear all media for a model (batch-optimized)
{:ok, count} = PhxMediaLibrary.clear_media(post)
```

Both `clear_collection/2` and `clear_media/1` delete files from storage for
each item, then remove all matching database records in a single `DELETE` query
(avoiding N+1).

## Mix tasks

### Install

Generate the `media` table migration with all required fields:

```bash
mix phx_media_library.install
```

### Check and repair: the doctor

`mix phx_media_library.doctor` checks every media item and repairs what it
can. Without flags it only reports. Repairs show their plan and ask before
running (`--yes` skips the question, `--dry-run` only shows the plan).

The same checks and repairs are plain functions in `PhxMediaLibrary.Doctor`,
for code that runs without Mix (a scheduled job, an admin page):

```elixir
{:ok, report} = PhxMediaLibrary.Doctor.check(model: "products")
{:ok, %{done: done, failed: 0}} = PhxMediaLibrary.Doctor.repair(repairs: [:missing_placeholder])
```

```bash
mix phx_media_library.doctor                       # report
mix phx_media_library.doctor --regenerate          # missing conversions, WebP, AVIF, variants, placeholders
mix phx_media_library.doctor --reextract           # missing metadata (dimensions, EXIF)
mix phx_media_library.doctor --rename              # move files to their collection's file_naming (URLs change)
mix phx_media_library.doctor --drop-originals      # where WebP keep_original: false
mix phx_media_library.doctor --fix                 # delete records with no files left
mix phx_media_library.doctor --deep                # also verify checksums
mix phx_media_library.doctor --id <uuid> --regenerate
```

After changing settings, `--rebuild` regenerates derivatives that already
exist, all or `--only conversions,webp,avif,responsive,placeholders`
(`--conversion thumb` for one conversion). Narrow any run with `--model`,
`--collection` or `--disk`. `--strict` exits with status 1 when it finds
errors, for scheduled jobs.

The doctor replaced `regenerate`, `regenerate_webp`,
`regenerate_responsive` and `drop_originals`, which were removed in 0.10.

### Clean orphaned files

Remove files from storage that no longer have a database record, and
records whose files are gone. It works on local disks; use the doctor
elsewhere.

```bash
# Dry run: see what would be deleted
mix phx_media_library.clean

# Actually delete
mix phx_media_library.clean --force

# Only files, or only records
mix phx_media_library.clean --files-only
mix phx_media_library.clean --records-only
```

### Generate custom migration

Add custom fields to the media table:

```bash
mix phx_media_library.gen.migration add_blurhash_field
```

## Oban setup for async conversions

By default, PhxMediaLibrary uses `Task.Supervisor` for background conversion
processing. This is fine for development but doesn't survive restarts or
support retries. For production, use the Oban adapter.

### 1. Add Oban to your dependencies

```elixir
# mix.exs
{:oban, "~> 2.18"}
```

### 2. Configure Oban with a `:media` queue

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, media: 10]
```

Adjust concurrency based on your server capacity:

```elixir
# Low-traffic app
queues: [media: 5]

# High-traffic app with beefy servers
queues: [media: 20]
```

### 3. Tell PhxMediaLibrary to use the Oban adapter

```elixir
# config/config.exs
config :phx_media_library,
  async_processor: PhxMediaLibrary.AsyncProcessor.Oban
```

### 4. Start Oban in your supervision tree

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Oban, Application.fetch_env!(:my_app, Oban)},
  # ...
]
```

### How it works

When an image is uploaded (or any file to a collection with conversions),
PhxMediaLibrary enqueues an Oban job with the media ID, conversion names,
and the `mediable_type`. Images enqueue a job even without conversions,
for their placeholder. The `PhxMediaLibrary.Workers.ProcessConversions`
worker then:

1. Looks up the media record from the database
2. Discovers the originating Ecto schema module from the `mediable_type`
3. Retrieves the full `Conversion` definitions (width, height, quality, fit, etc.)
4. Processes each conversion and updates the media record
5. Makes the placeholders of the image and its new conversions

### Retry behaviour

The worker is configured with `max_attempts: 3`. Failed jobs use Oban's default
exponential backoff. You can monitor failed jobs via `Oban.Web` or your own
telemetry handlers.

### Synchronous processing

If you need conversions to complete immediately (e.g. generating a thumbnail
before returning a response), call `process_sync/2` directly:

```elixir
PhxMediaLibrary.AsyncProcessor.Oban.process_sync(media, conversions)
```

## Testing

### In-memory storage

For tests, use the in-memory storage adapter to avoid filesystem side effects:

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

Start the memory storage agent in your `test_helper.exs`:

```elixir
{:ok, _} = PhxMediaLibrary.Storage.Memory.start_link()
```

### Test fixtures

Create test fixture files in `test/support/fixtures/` and use them in your
tests:

```elixir
defmodule MyApp.MediaFixtures do
  @fixtures_path Path.join([__DIR__, "..", "support", "fixtures"])

  def fixture_path(filename), do: Path.join(@fixtures_path, filename)

  def sample_image, do: fixture_path("sample.jpg")
  def sample_pdf, do: fixture_path("sample.pdf")
end
```

### Testing media addition

```elixir
defmodule MyApp.PostMediaTest do
  use MyApp.DataCase

  alias PhxMediaLibrary

  test "adds an image to a post" do
    post = insert(:post)

    assert {:ok, media} =
             post
             |> PhxMediaLibrary.add(fixture_path("sample.jpg"))
             |> PhxMediaLibrary.to_collection(:images)

    assert media.collection_name == "images"
    assert media.mime_type == "image/jpeg"
    assert media.size > 0
  end

  test "rejects files exceeding max_size" do
    post = insert(:post)

    assert {:error, {:file_too_large, _actual, _max}} =
             post
             |> PhxMediaLibrary.add(fixture_path("large_file.bin"))
             |> PhxMediaLibrary.to_collection(:uploads)
  end

  test "rejects invalid MIME types" do
    post = insert(:post)

    assert {:error, :invalid_mime_type} =
             post
             |> PhxMediaLibrary.add(fixture_path("sample.exe"))
             |> PhxMediaLibrary.to_collection(:images)
  end
end
```

### Testing with telemetry

Attach telemetry handlers in tests to verify events are emitted:

```elixir
test "emits telemetry on media add" do
  ref = make_ref()
  test_pid = self()

  :telemetry.attach(
    "test-#{inspect(ref)}",
    [:phx_media_library, :add, :stop],
    fn _event, measurements, metadata, _config ->
      send(test_pid, {:telemetry, measurements, metadata})
    end,
    nil
  )

  post = insert(:post)

  {:ok, _media} =
    post
    |> PhxMediaLibrary.add(fixture_path("sample.jpg"))
    |> PhxMediaLibrary.to_collection(:images)

  assert_receive {:telemetry, %{duration: duration}, %{collection: :images}}
  assert duration > 0

  :telemetry.detach("test-#{inspect(ref)}")
end
```

### Temporary directory pattern

For tests that need real files on disk, use the `tmp_dir` ExUnit tag:

```elixir
@tag :tmp_dir
test "stores file to disk", %{tmp_dir: tmp_dir} do
  # Configure storage to use the temp directory
  # Files are automatically cleaned up after the test
end
```
