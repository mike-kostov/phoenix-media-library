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
end
