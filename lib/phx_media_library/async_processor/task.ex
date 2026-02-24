defmodule PhxMediaLibrary.AsyncProcessor.Task do
  @moduledoc """
  Default async processor using Task.Supervisor.

  This provides simple async processing without requiring external dependencies.
  Note that tasks are not persisted - if the application crashes, pending
  conversions will be lost.

  For production apps that need reliability, consider using the Oban adapter.
  """

  @behaviour PhxMediaLibrary.AsyncProcessor

  alias PhxMediaLibrary.Conversions

  @impl true
  def process_async(media, conversions) do
    Task.Supervisor.start_child(
      PhxMediaLibrary.TaskSupervisor,
      fn -> Conversions.process(media, conversions) end
    )

    :ok
  end

  @impl true
  def process_sync(media, conversions) do
    Conversions.process(media, conversions)
  end
end
