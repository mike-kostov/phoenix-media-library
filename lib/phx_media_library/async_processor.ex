defmodule PhxMediaLibrary.AsyncProcessor do
  @moduledoc """
  Behaviour for async processing adapters.

  The default implementation uses `Task.Supervisor` for simple async processing.
  For production apps with persistence and retry requirements, use the Oban adapter.
  """

  alias PhxMediaLibrary.{Media, Conversion}

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
