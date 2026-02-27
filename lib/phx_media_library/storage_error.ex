defmodule PhxMediaLibrary.StorageError do
  @moduledoc """
  Exception raised when a storage operation fails.

  This covers errors from any storage backend (local disk, S3, memory, or
  custom adapters) such as failed reads, writes, deletes, or connectivity
  issues.

  ## Fields

  - `:message` — human-readable error description
  - `:reason` — machine-readable atom identifying the error (e.g. `:write_failed`, `:not_found`)
  - `:operation` — the storage operation that failed (e.g. `:put`, `:get`, `:delete`, `:exists?`)
  - `:path` — the storage path involved, if available
  - `:adapter` — the storage adapter module that raised the error, if available
  - `:metadata` — optional map with additional context

  ## Examples

      iex> raise PhxMediaLibrary.StorageError,
      ...>   message: "failed to write file",
      ...>   reason: :write_failed,
      ...>   operation: :put,
      ...>   path: "posts/abc/image.jpg"
      ** (PhxMediaLibrary.StorageError) failed to write file

      iex> error = %PhxMediaLibrary.StorageError{
      ...>   message: "file not found",
      ...>   reason: :not_found,
      ...>   operation: :get,
      ...>   path: "posts/abc/image.jpg"
      ...> }
      iex> error.reason
      :not_found

  """

  @type t :: %__MODULE__{
          message: String.t(),
          reason: atom(),
          operation: atom() | nil,
          path: String.t() | nil,
          adapter: module() | nil,
          metadata: map()
        }

  defexception [:message, :reason, :operation, :path, :adapter, :metadata]

  @impl true
  def exception(opts) when is_list(opts) do
    reason = Keyword.get(opts, :reason, :unknown)
    operation = Keyword.get(opts, :operation)
    path = Keyword.get(opts, :path)
    adapter = Keyword.get(opts, :adapter)
    metadata = Keyword.get(opts, :metadata, %{})
    message = Keyword.get(opts, :message, default_message(reason, operation, path))

    %__MODULE__{
      message: message,
      reason: reason,
      operation: operation,
      path: path,
      adapter: adapter,
      metadata: metadata
    }
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{
      message: message,
      reason: :unknown,
      operation: nil,
      path: nil,
      adapter: nil,
      metadata: %{}
    }
  end

  defp default_message(reason, operation, path) do
    parts =
      ["Storage error"]
      |> maybe_append_operation(operation)
      |> maybe_append_path(path)
      |> maybe_append_reason(reason)

    Enum.join(parts, "")
  end

  defp maybe_append_operation(parts, nil), do: parts
  defp maybe_append_operation(parts, op), do: parts ++ [" during #{op}"]

  defp maybe_append_path(parts, nil), do: parts
  defp maybe_append_path(parts, path), do: parts ++ [" at path \"#{path}\""]

  defp maybe_append_reason(parts, :unknown), do: parts
  defp maybe_append_reason(parts, reason), do: parts ++ [": #{reason}"]
end
