# Telemetry

PhxMediaLibrary emits [Telemetry](https://hexdocs.pm/telemetry) events for its
key operations, so you can monitor, log, and collect metrics in your
application. Every span follows the `:start` / `:stop` / `:exception`
convention.

## Events

All event names begin with `[:phx_media_library, ...]`.

### Media addition

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:phx_media_library, :add, :start]` | `%{system_time: integer()}` | `%{collection: atom(), source_type: atom(), model: struct()}` |
| `[:phx_media_library, :add, :stop]` | `%{duration: integer()}` | `%{collection: atom(), source_type: atom(), model: struct(), media: Media.t()}` |
| `[:phx_media_library, :add, :exception]` | `%{duration: integer()}` | `%{collection: atom(), source_type: atom(), model: struct(), kind: atom(), reason: term(), stacktrace: list()}` |

### Media deletion

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:phx_media_library, :delete, :start]` | `%{system_time: integer()}` | `%{media: Media.t()}` |
| `[:phx_media_library, :delete, :stop]` | `%{duration: integer()}` | `%{media: Media.t()}` |
| `[:phx_media_library, :delete, :exception]` | `%{duration: integer()}` | `%{media: Media.t(), kind: atom(), reason: term(), stacktrace: list()}` |

### Image conversions

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:phx_media_library, :conversion, :start]` | `%{system_time: integer()}` | `%{media: Media.t(), conversion: atom()}` |
| `[:phx_media_library, :conversion, :stop]` | `%{duration: integer()}` | `%{media: Media.t(), conversion: atom()}` |
| `[:phx_media_library, :conversion, :exception]` | `%{duration: integer()}` | `%{media: Media.t(), conversion: atom(), kind: atom(), reason: term(), stacktrace: list()}` |

### Storage operations

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:phx_media_library, :storage, :start]` | `%{system_time: integer()}` | `%{operation: atom(), path: String.t(), adapter: module()}` |
| `[:phx_media_library, :storage, :stop]` | `%{duration: integer()}` | `%{operation: atom(), path: String.t(), adapter: module()}` |
| `[:phx_media_library, :storage, :exception]` | `%{duration: integer()}` | `%{operation: atom(), path: String.t(), adapter: module(), kind: atom(), reason: term(), stacktrace: list()}` |

### Batch operations

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:phx_media_library, :batch, :start]` | `%{system_time: integer()}` | `%{operation: atom(), count: integer()}` |
| `[:phx_media_library, :batch, :stop]` | `%{duration: integer()}` | `%{operation: atom(), count: integer()}` |
| `[:phx_media_library, :batch, :exception]` | `%{duration: integer()}` | `%{operation: atom(), count: integer(), kind: atom(), reason: term(), stacktrace: list()}` |

### Remote downloads

Emitted when you add media from a URL via `add_from_url/3`.

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:phx_media_library, :download, :start]` | `%{system_time: integer()}` | `%{url: String.t()}` |
| `[:phx_media_library, :download, :stop]` | `%{duration: integer()}` | `%{url: String.t(), size: integer(), mime_type: String.t()}` |
| `[:phx_media_library, :download, :exception]` | `%{duration: integer()}` | `%{url: String.t(), error: term(), kind: atom(), reason: term(), stacktrace: list()}` |

### Reorder

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:phx_media_library, :reorder]` | `%{count: integer()}` | `%{model: struct(), collection: atom()}` |

> **Note:** Duration values are in native time units. Use
> `System.convert_time_unit(duration, :native, :millisecond)` to convert.

## Attaching handlers

Attach handlers in your application's `start/2` callback:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  :telemetry.attach_many(
  "my-app-media-handler",
  [
    [:phx_media_library, :add, :stop],
    [:phx_media_library, :add, :exception],
    [:phx_media_library, :delete, :stop],
    [:phx_media_library, :storage, :stop],
    [:phx_media_library, :batch, :stop],
    [:phx_media_library, :download, :stop],
    [:phx_media_library, :download, :exception]
  ],
    &MyApp.TelemetryHandler.handle_event/4,
    nil
  )

  children = [
    # ...
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Example: logging handler

```elixir
defmodule MyApp.TelemetryHandler do
  require Logger

  def handle_event([:phx_media_library, :add, :stop], measurements, metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "[Media] Added to #{metadata.collection} in #{ms}ms " <>
        "(media_id=#{metadata.media.id})"
    )
  end

  def handle_event([:phx_media_library, :add, :exception], measurements, metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Media] Failed to add to #{metadata.collection} after #{ms}ms: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  def handle_event([:phx_media_library, :delete, :stop], measurements, _metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("[Media] Deleted in #{ms}ms")
  end

  def handle_event([:phx_media_library, :storage, :stop], measurements, metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Media] Storage #{metadata.operation} on #{metadata.path} " <>
        "via #{inspect(metadata.adapter)} in #{ms}ms"
    )
  end

  def handle_event([:phx_media_library, :batch, :stop], measurements, metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("[Media] Batch #{metadata.operation} (#{metadata.count} items) in #{ms}ms")
  end

  def handle_event([:phx_media_library, :download, :stop], measurements, metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "[Media] Downloaded #{metadata.url} " <>
        "(#{metadata.size} bytes, #{metadata.mime_type}) in #{ms}ms"
    )
  end

  def handle_event([:phx_media_library, :download, :exception], _measurements, metadata, _config) do
    Logger.error("[Media] Download failed for #{metadata.url}: #{inspect(metadata.error)}")
  end
end
```

## Example: StatsD / Prometheus metrics

If you use a metrics library like `telemetry_metrics`, you can define metrics
declaratively:

```elixir
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsStatsd, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Timing
      summary("phx_media_library.add.stop.duration",
        unit: {:native, :millisecond},
        tags: [:collection]
      ),
      summary("phx_media_library.storage.stop.duration",
        unit: {:native, :millisecond},
        tags: [:operation, :adapter]
      ),
      summary("phx_media_library.download.stop.duration",
        unit: {:native, :millisecond}
      ),

      # Counters
      counter("phx_media_library.add.stop.duration",
        tags: [:collection]
      ),
      counter("phx_media_library.add.exception.duration",
        tags: [:collection]
      ),
      counter("phx_media_library.delete.stop.duration"),
      counter("phx_media_library.download.stop.duration"),
      counter("phx_media_library.download.exception.duration"),

      # Batch sizes
      summary("phx_media_library.batch.stop.duration",
        unit: {:native, :millisecond},
        tags: [:operation]
      )
    ]
  end
end
```

## Built-in debug logging

PhxMediaLibrary includes built-in debug-level Logger integration via
`PhxMediaLibrary.Telemetry`. When you set your application's log level to
`:debug`, you'll see log lines for key operations without attaching any custom
handlers.

See the `PhxMediaLibrary.Telemetry` module documentation for full details.