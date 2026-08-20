defmodule PhxMediaLibrary.AsyncProcessor.Inline do
  @moduledoc """
  Synchronous conversion processor — runs conversions inline, in the calling
  process, instead of spawning a task.

  Use this when you want conversions completed before `to_collection/3` returns
  (deterministic, no `Task.Supervisor`), e.g. in tests, scripts, or small apps:

      config :phx_media_library, async_processor: PhxMediaLibrary.AsyncProcessor.Inline
  """

  @behaviour PhxMediaLibrary.AsyncProcessor

  alias PhxMediaLibrary.Conversions

  @impl true
  def process_async(media, conversions), do: process_sync(media, conversions)

  @impl true
  def process_sync(media, conversions) do
    Conversions.process(media, conversions)
    :ok
  end
end
