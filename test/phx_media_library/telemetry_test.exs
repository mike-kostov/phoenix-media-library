defmodule PhxMediaLibrary.TelemetryTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Telemetry

  # ---------------------------------------------------------------------------
  # Helper: attach a telemetry handler that sends events to the test process
  # ---------------------------------------------------------------------------

  defp attach_handler(event_names, handler_id \\ nil) do
    id = handler_id || "test-handler-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      id,
      event_names,
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    id
  end

  # ---------------------------------------------------------------------------
  # Telemetry.span/3
  # ---------------------------------------------------------------------------

  describe "span/3" do
    test "emits :start and :stop events on success" do
      attach_handler([
        [:phx_media_library, :test_span, :start],
        [:phx_media_library, :test_span, :stop]
      ])

      result =
        Telemetry.span(
          [:phx_media_library, :test_span],
          %{collection: :images},
          fn ->
            {"the result", %{extra: :data}}
          end
        )

      assert result == "the result"

      assert_received {:telemetry_event, [:phx_media_library, :test_span, :start],
                       start_measurements, start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.collection == :images

      assert_received {:telemetry_event, [:phx_media_library, :test_span, :stop],
                       stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.collection == :images
      assert stop_metadata.extra == :data
    end

    test "merges stop metadata with start metadata" do
      attach_handler([
        [:phx_media_library, :test_merge, :stop]
      ])

      Telemetry.span(
        [:phx_media_library, :test_merge],
        %{original: :value},
        fn ->
          {:ok, %{added: :later}}
        end
      )

      assert_received {:telemetry_event, [:phx_media_library, :test_merge, :stop], _measurements,
                       metadata}

      assert metadata.original == :value
      assert metadata.added == :later
    end

    test "returns the result of the function" do
      result =
        Telemetry.span(
          [:phx_media_library, :test_return],
          %{},
          fn ->
            {{:ok, 42}, %{}}
          end
        )

      assert result == {:ok, 42}
    end

    test "emits :exception event when function raises" do
      attach_handler([
        [:phx_media_library, :test_raise, :start],
        [:phx_media_library, :test_raise, :exception]
      ])

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span(
          [:phx_media_library, :test_raise],
          %{context: :test},
          fn ->
            raise "boom"
          end
        )
      end

      assert_received {:telemetry_event, [:phx_media_library, :test_raise, :start], _, _}

      assert_received {:telemetry_event, [:phx_media_library, :test_raise, :exception],
                       exception_measurements, exception_metadata}

      assert is_integer(exception_measurements.duration)
      assert exception_metadata.kind == :error
      assert %RuntimeError{message: "boom"} = exception_metadata.reason
      assert is_list(exception_metadata.stacktrace)
    end

    test "works with empty metadata" do
      attach_handler([
        [:phx_media_library, :test_empty, :start],
        [:phx_media_library, :test_empty, :stop]
      ])

      result =
        Telemetry.span(
          [:phx_media_library, :test_empty],
          %{},
          fn ->
            {"value", %{}}
          end
        )

      assert result == "value"

      assert_received {:telemetry_event, [:phx_media_library, :test_empty, :start], _, _}
      assert_received {:telemetry_event, [:phx_media_library, :test_empty, :stop], _, _}
    end

    test "duration is non-negative" do
      attach_handler([
        [:phx_media_library, :test_duration, :stop]
      ])

      Telemetry.span(
        [:phx_media_library, :test_duration],
        %{},
        fn ->
          Process.sleep(1)
          {:ok, %{}}
        end
      )

      assert_received {:telemetry_event, [:phx_media_library, :test_duration, :stop],
                       %{duration: duration}, _}

      assert duration > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry.event/3
  # ---------------------------------------------------------------------------

  describe "event/3" do
    test "emits a standalone telemetry event" do
      attach_handler([
        [:phx_media_library, :reorder]
      ])

      :ok =
        Telemetry.event(
          [:phx_media_library, :reorder],
          %{count: 5},
          %{model: "post", collection: :images}
        )

      assert_received {:telemetry_event, [:phx_media_library, :reorder], measurements, metadata}
      assert measurements.count == 5
      assert metadata.model == "post"
      assert metadata.collection == :images
    end

    test "emits with empty measurements and metadata" do
      attach_handler([
        [:phx_media_library, :ping]
      ])

      :ok = Telemetry.event([:phx_media_library, :ping], %{}, %{})

      assert_received {:telemetry_event, [:phx_media_library, :ping], %{}, %{}}
    end

    test "returns :ok" do
      assert :ok = Telemetry.event([:phx_media_library, :noop], %{}, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: event prefixes used by the library
  # ---------------------------------------------------------------------------

  describe "library event prefixes" do
    test "add span emits expected events" do
      attach_handler([
        [:phx_media_library, :add, :start],
        [:phx_media_library, :add, :stop]
      ])

      Telemetry.span(
        [:phx_media_library, :add],
        %{collection: :images, source_type: :path},
        fn ->
          {{:ok, :fake_media}, %{media: :fake_media}}
        end
      )

      assert_received {:telemetry_event, [:phx_media_library, :add, :start], _, metadata}
      assert metadata.collection == :images
      assert metadata.source_type == :path

      assert_received {:telemetry_event, [:phx_media_library, :add, :stop], _, metadata}
      assert metadata.media == :fake_media
    end

    test "delete span emits expected events" do
      attach_handler([
        [:phx_media_library, :delete, :start],
        [:phx_media_library, :delete, :stop]
      ])

      Telemetry.span(
        [:phx_media_library, :delete],
        %{media: :fake_media},
        fn ->
          {:ok, %{media: :fake_media}}
        end
      )

      assert_received {:telemetry_event, [:phx_media_library, :delete, :start], _,
                       %{media: :fake_media}}

      assert_received {:telemetry_event, [:phx_media_library, :delete, :stop], _,
                       %{media: :fake_media}}
    end

    test "conversion span emits expected events" do
      attach_handler([
        [:phx_media_library, :conversion, :start],
        [:phx_media_library, :conversion, :stop]
      ])

      Telemetry.span(
        [:phx_media_library, :conversion],
        %{media: :fake_media, conversion: :thumb},
        fn ->
          {{:ok, :thumb}, %{conversion: :thumb}}
        end
      )

      assert_received {:telemetry_event, [:phx_media_library, :conversion, :start], _,
                       %{conversion: :thumb}}

      assert_received {:telemetry_event, [:phx_media_library, :conversion, :stop], _,
                       %{conversion: :thumb}}
    end

    test "storage span emits expected events" do
      attach_handler([
        [:phx_media_library, :storage, :start],
        [:phx_media_library, :storage, :stop]
      ])

      Telemetry.span(
        [:phx_media_library, :storage],
        %{operation: :put, path: "test/path.jpg", adapter: FakeAdapter},
        fn ->
          {:ok, %{operation: :put, path: "test/path.jpg", adapter: FakeAdapter}}
        end
      )

      assert_received {:telemetry_event, [:phx_media_library, :storage, :start], _, metadata}
      assert metadata.operation == :put
      assert metadata.path == "test/path.jpg"
      assert metadata.adapter == FakeAdapter

      assert_received {:telemetry_event, [:phx_media_library, :storage, :stop], _, _}
    end

    test "batch span emits expected events" do
      attach_handler([
        [:phx_media_library, :batch, :start],
        [:phx_media_library, :batch, :stop]
      ])

      Telemetry.span(
        [:phx_media_library, :batch],
        %{operation: :clear_collection, count: 10},
        fn ->
          {{:ok, 10}, %{operation: :clear_collection, count: 10}}
        end
      )

      assert_received {:telemetry_event, [:phx_media_library, :batch, :start], _,
                       %{operation: :clear_collection, count: 10}}

      assert_received {:telemetry_event, [:phx_media_library, :batch, :stop], _,
                       %{operation: :clear_collection, count: 10}}
    end
  end
end
