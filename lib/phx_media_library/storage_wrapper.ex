defmodule PhxMediaLibrary.StorageWrapper do
  @moduledoc false
  # Wraps a storage adapter to automatically pass config and emit Telemetry events.

  alias PhxMediaLibrary.Telemetry

  defstruct [:adapter, :config]

  def put(%__MODULE__{adapter: adapter, config: config}, path, content) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :put, path: path, adapter: adapter},
      fn ->
        result = adapter.put(path, content, config)
        {result, %{operation: :put, path: path, adapter: adapter}}
      end
    )
  end

  def get(%__MODULE__{adapter: adapter, config: config}, path) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :get, path: path, adapter: adapter},
      fn ->
        result = adapter.get(path, config)
        {result, %{operation: :get, path: path, adapter: adapter}}
      end
    )
  end

  def delete(%__MODULE__{adapter: adapter, config: config}, path) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :delete, path: path, adapter: adapter},
      fn ->
        result = adapter.delete(path, config)
        {result, %{operation: :delete, path: path, adapter: adapter}}
      end
    )
  end

  def exists?(%__MODULE__{adapter: adapter, config: config}, path) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :exists?, path: path, adapter: adapter},
      fn ->
        result = adapter.exists?(path, config)
        {result, %{operation: :exists?, path: path, adapter: adapter}}
      end
    )
  end

  def url(%__MODULE__{adapter: adapter, config: config}, path, opts \\ []) do
    adapter.url(path, Keyword.merge(config, opts))
  end

  @doc """
  Generate a presigned upload URL for direct client-to-storage uploads.

  Returns `{:ok, url, fields}` if the adapter supports presigned URLs,
  or `{:error, :not_supported}` if it doesn't.
  """
  def presigned_upload_url(
        %__MODULE__{adapter: adapter, config: config},
        path,
        presigned_opts \\ []
      ) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :presigned_upload_url, 3) do
      Telemetry.span(
        [:phx_media_library, :storage],
        %{operation: :presigned_upload_url, path: path, adapter: adapter},
        fn ->
          result = adapter.presigned_upload_url(path, presigned_opts, config)
          {result, %{operation: :presigned_upload_url, path: path, adapter: adapter}}
        end
      )
    else
      {:error, :not_supported}
    end
  end
end
