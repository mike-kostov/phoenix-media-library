defmodule PhxMediaLibrary.RecordingAsyncProcessor do
  @moduledoc """
  Async processor for tests: records `process_async/2` calls as
  `{:process_async, media_id, conversion_names}` messages to the process
  given to `record_to/1`, without running them, so tests can see what an
  upload leaves for the background. `process_sync/2` runs inline.
  """

  @behaviour PhxMediaLibrary.AsyncProcessor

  @doc "Send recorded calls to `pid`."
  def record_to(pid), do: Application.put_env(:phx_media_library, __MODULE__, pid)

  @impl true
  def process_async(media, conversions) do
    pid = Application.fetch_env!(:phx_media_library, __MODULE__)
    send(pid, {:process_async, media.id, Enum.map(conversions, & &1.name)})
    :ok
  end

  @impl true
  def process_sync(media, conversions),
    do: PhxMediaLibrary.Conversions.process(media, conversions)
end
