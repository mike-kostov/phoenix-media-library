defmodule PhxMediaLibrary.Telemetry do
  @moduledoc """
  Telemetry integration for PhxMediaLibrary.

  PhxMediaLibrary emits [Telemetry](https://hexdocs.pm/telemetry) events for
  key operations, enabling monitoring, logging, and metrics collection in
  your application.

  ## Events

  All events are prefixed with `[:phx_media_library, ...]`.

  ### Media Addition

  - `[:phx_media_library, :add, :start]` — emitted when media addition begins.

    Measurements: `%{system_time: integer()}`

    Metadata: `%{collection: atom(), source_type: atom(), model: struct()}`

  - `[:phx_media_library, :add, :stop]` — emitted when media addition completes successfully.

    Measurements: `%{duration: integer()}` (in native time units)

    Metadata: `%{collection: atom(), source_type: atom(), model: struct(), media: Media.t()}`

  - `[:phx_media_library, :add, :exception]` — emitted when media addition fails with an exception.

    Measurements: `%{duration: integer()}`

    Metadata: `%{collection: atom(), source_type: atom(), model: struct(), kind: atom(), reason: term(), stacktrace: list()}`

  ### Media Deletion

  - `[:phx_media_library, :delete, :start]` — emitted when media deletion begins.

    Measurements: `%{system_time: integer()}`

    Metadata: `%{media: Media.t()}`

  - `[:phx_media_library, :delete, :stop]` — emitted when media deletion completes.

    Measurements: `%{duration: integer()}`

    Metadata: `%{media: Media.t()}`

  - `[:phx_media_library, :delete, :exception]` — emitted when media deletion fails.

    Measurements: `%{duration: integer()}`

    Metadata: `%{media: Media.t(), kind: atom(), reason: term(), stacktrace: list()}`

  ### Image Conversions

  - `[:phx_media_library, :conversion, :start]` — emitted when a conversion begins.

    Measurements: `%{system_time: integer()}`

    Metadata: `%{media: Media.t(), conversion: atom()}`

  - `[:phx_media_library, :conversion, :stop]` — emitted when a conversion completes.

    Measurements: `%{duration: integer()}`

    Metadata: `%{media: Media.t(), conversion: atom()}`

  - `[:phx_media_library, :conversion, :exception]` — emitted when a conversion fails.

    Measurements: `%{duration: integer()}`

    Metadata: `%{media: Media.t(), conversion: atom(), kind: atom(), reason: term(), stacktrace: list()}`

  ### Storage Operations

  - `[:phx_media_library, :storage, :start]` — emitted when a storage operation begins.

    Measurements: `%{system_time: integer()}`

    Metadata: `%{operation: atom(), path: String.t(), adapter: module()}`

  - `[:phx_media_library, :storage, :stop]` — emitted when a storage operation completes.

    Measurements: `%{duration: integer()}`

    Metadata: `%{operation: atom(), path: String.t(), adapter: module()}`

  - `[:phx_media_library, :storage, :exception]` — emitted when a storage operation fails.

    Measurements: `%{duration: integer()}`

    Metadata: `%{operation: atom(), path: String.t(), adapter: module(), kind: atom(), reason: term(), stacktrace: list()}`

  ### Remote Downloads

  - `[:phx_media_library, :download, :start]` — emitted when a remote URL download begins.

    Measurements: `%{system_time: integer()}`

    Metadata: `%{url: String.t()}`

  - `[:phx_media_library, :download, :stop]` — emitted when a remote URL download completes.

    Measurements: `%{duration: integer()}`

    Metadata: `%{url: String.t(), size: integer(), mime_type: String.t()}`

  - `[:phx_media_library, :download, :exception]` — emitted when a remote URL download fails.

    Measurements: `%{duration: integer()}`

    Metadata: `%{url: String.t(), error: term(), kind: atom(), reason: term(), stacktrace: list()}`

  ### Batch Operations

  - `[:phx_media_library, :batch, :start]` — emitted when a batch operation begins.

    Measurements: `%{system_time: integer()}`

    Metadata: `%{operation: atom(), count: integer()}`

  - `[:phx_media_library, :batch, :stop]` — emitted when a batch operation completes.

    Measurements: `%{duration: integer()}`

    Metadata: `%{operation: atom(), count: integer()}`

  - `[:phx_media_library, :batch, :exception]` — emitted when a batch operation fails.

    Measurements: `%{duration: integer()}`

    Metadata: `%{operation: atom(), count: integer(), kind: atom(), reason: term(), stacktrace: list()}`

  ## Usage

  Attach handlers in your application's `start/2` callback:

      # In your Application module
      def start(_type, _args) do
        :telemetry.attach_many(
          "my-app-media-handler",
          [
            [:phx_media_library, :add, :stop],
            [:phx_media_library, :add, :exception],
            [:phx_media_library, :delete, :stop],
            [:phx_media_library, :storage, :stop]
          ],
          &MyApp.TelemetryHandler.handle_event/4,
          nil
        )

        # ... rest of supervision tree
      end

  Or use a `Telemetry.Metrics`-based approach:

      # In your Telemetry module
      def metrics do
        [
          counter("phx_media_library.add.stop.duration"),
          counter("phx_media_library.delete.stop.duration"),
          distribution("phx_media_library.add.stop.duration",
            buckets: [100, 500, 1_000, 5_000, 10_000]
          ),
          counter("phx_media_library.add.exception.duration",
            tags: [:reason]
          )
        ]
      end

  """

  require Logger

  @doc """
  Execute a span for the given event prefix.

  Emits `:start`, `:stop`, and `:exception` events with timing information.
  This is a thin wrapper around `:telemetry.span/3` that also logs at debug
  level for development convenience.

  ## Parameters

  - `event_prefix` — list of atoms, e.g. `[:phx_media_library, :add]`
  - `metadata` — map of metadata to attach to all three events
  - `fun` — zero-arity function to execute. Must return `{result, stop_metadata}`
    where `stop_metadata` is merged into the `:stop` event metadata

  ## Examples

      PhxMediaLibrary.Telemetry.span(
        [:phx_media_library, :add],
        %{collection: :images, model: post},
        fn ->
          result = do_add_media(post, source)
          {result, %{media: result}}
        end
      )

  """
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_map(metadata) do
    :telemetry.span(event_prefix, metadata, fn ->
      log_start(event_prefix, metadata)
      {result, extra_metadata} = fun.()
      log_stop(event_prefix, metadata, extra_metadata)
      {result, Map.merge(metadata, extra_metadata)}
    end)
  rescue
    e ->
      log_exception(event_prefix, metadata, e)
      reraise e, __STACKTRACE__
  end

  @doc """
  Emit a standalone telemetry event (not part of a span).

  Useful for one-shot events that don't wrap a block of work, such as
  `:media_reordered` or other notification-style events.

  ## Examples

      PhxMediaLibrary.Telemetry.event(
        [:phx_media_library, :reorder],
        %{count: 5},
        %{model: post, collection: :images}
      )

  """
  @spec event([atom()], map(), map()) :: :ok
  def event(event_name, measurements, metadata)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  # ---------------------------------------------------------------------------
  # Debug logging helpers
  # ---------------------------------------------------------------------------

  defp log_start(event_prefix, metadata) do
    event_name = format_event(event_prefix)

    Logger.debug(fn ->
      "[PhxMediaLibrary] #{event_name} started #{format_metadata(metadata)}"
    end)
  end

  defp log_stop(event_prefix, metadata, extra_metadata) do
    event_name = format_event(event_prefix)

    Logger.debug(fn ->
      all_meta = Map.merge(metadata, extra_metadata)
      "[PhxMediaLibrary] #{event_name} completed #{format_metadata(all_meta)}"
    end)
  end

  defp log_exception(event_prefix, metadata, exception) do
    event_name = format_event(event_prefix)

    Logger.warning(fn ->
      "[PhxMediaLibrary] #{event_name} failed: #{Exception.message(exception)} #{format_metadata(metadata)}"
    end)
  end

  defp format_event(event_prefix) do
    Enum.map_join(event_prefix, ".", &Atom.to_string/1)
  end

  defp format_metadata(metadata) when map_size(metadata) == 0, do: ""

  defp format_metadata(metadata) do
    # Only include simple, loggable values — skip structs and large maps
    metadata
    |> Enum.filter(fn {_k, v} -> loggable?(v) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> case do
      "" -> ""
      str -> "(#{str})"
    end
  end

  defp loggable?(v) when is_atom(v), do: true
  defp loggable?(v) when is_binary(v), do: true
  defp loggable?(v) when is_number(v), do: true
  defp loggable?(v) when is_list(v), do: true
  defp loggable?(_), do: false
end
