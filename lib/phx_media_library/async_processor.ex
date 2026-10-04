defmodule PhxMediaLibrary.AsyncProcessor do
  @moduledoc """
  Behaviour for async processing adapters: what runs conversions and
  placeholders after an upload.

  The default implementation uses `Task.Supervisor` for simple async processing.
  For production apps with persistence and retry requirements, use the Oban adapter.

      config :phx_media_library, async_processor: PhxMediaLibrary.AsyncProcessor.Oban

  A custom adapter implements both callbacks and hands the work to
  `PhxMediaLibrary.Conversions.process/2`:

      defmodule MyApp.MediaProcessor do
        @behaviour PhxMediaLibrary.AsyncProcessor

        @impl true
        def process_async(media, conversions) do
          MyApp.Jobs.enqueue(fn -> PhxMediaLibrary.Conversions.process(media, conversions) end)
          :ok
        end

        @impl true
        def process_sync(media, conversions), do: PhxMediaLibrary.Conversions.process(media, conversions)
      end
  """

  alias PhxMediaLibrary.{Conversion, Media}

  @doc """
  Process conversions asynchronously.
  """
  @callback process_async(media :: Media.t(), conversions :: [Conversion.t()]) ::
              :ok | {:error, term()}

  @doc """
  Process conversions synchronously (for testing or immediate needs).
  """
  @callback process_sync(media :: Media.t(), conversions :: [Conversion.t()]) ::
              :ok | {:error, term()}

  @optional_callbacks [process_sync: 2]
end
