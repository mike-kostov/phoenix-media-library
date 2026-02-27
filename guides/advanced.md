# Advanced Usage

This guide covers reordering, mix tasks, and testing strategies.

## Reordering Media

Media items within a collection have an `order_column` that controls their
display order. PhxMediaLibrary provides two functions for managing order.

### Reorder by ID List

Set the exact order for all items in a collection by passing an ordered list of
IDs. This runs in a single database transaction:

```elixir
# Set explicit order: id3 first, id1 second, id2 third
{:ok, count} = PhxMediaLibrary.reorder(post, :images, [id3, id1, id2])
```

IDs not present in the collection are silently ignored. Items whose IDs are not
in the provided list keep their current order but are shifted after the
explicitly ordered items.

### Move a Single Item

Move one media item to a specific 1-based position within its collection:

```elixir
{:ok, updated_media} = PhxMediaLibrary.move_to(media, 1)   # move to first
{:ok, updated_media} = PhxMediaLibrary.move_to(media, 3)   # move to third
```

The position is clamped to the valid range — passing a position larger than the
collection size moves the item to the end.

### Drag-and-Drop Reordering

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

## Deleting Media

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

## Mix Tasks

### Install

Generate the `media` table migration with all required fields:

```bash
mix phx_media_library.install
```

### Regenerate Conversions

Regenerate derived images after changing conversion definitions:

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

Remove files from storage that no longer have a corresponding database record:

```bash
# Dry run — see what would be deleted
mix phx_media_library.clean

# Actually delete
mix phx_media_library.clean --force
```

### Generate Custom Migration

Add custom fields to the media table:

```bash
mix phx_media_library.gen.migration add_blurhash_field
```

## Oban Setup for Async Conversions

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

### How It Works

When media is uploaded and conversions are defined, PhxMediaLibrary enqueues an
Oban job with the media ID, conversion names, and the `mediable_type`. The
`PhxMediaLibrary.Workers.ProcessConversions` worker then:

1. Looks up the media record from the database
2. Discovers the originating Ecto schema module from the `mediable_type`
3. Retrieves the full `Conversion` definitions (width, height, quality, fit, etc.)
4. Processes each conversion and updates the media record

### Retry Behaviour

The worker is configured with `max_attempts: 3`. Failed jobs use Oban's default
exponential backoff. You can monitor failed jobs via `Oban.Web` or your own
telemetry handlers.

### Synchronous Processing

If you need conversions to complete immediately (e.g. generating a thumbnail
before returning a response), call `process_sync/2` directly:

```elixir
PhxMediaLibrary.AsyncProcessor.Oban.process_sync(media, conversions)
```

## Testing

### In-Memory Storage

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

### Test Fixtures

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

### Testing Media Addition

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

### Testing with Telemetry

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

### Temporary Directory Pattern

For tests that need real files on disk, use the `tmp_dir` ExUnit tag:

```elixir
@tag :tmp_dir
test "stores file to disk", %{tmp_dir: tmp_dir} do
  # Configure storage to use the temp directory
  # Files are automatically cleaned up after the test
end
```
