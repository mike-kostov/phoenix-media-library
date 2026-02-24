defmodule PhxMediaLibrary.StorageWrapper do
  @moduledoc false
  # Wraps a storage adapter to automatically pass config

  defstruct [:adapter, :config]

  def put(%__MODULE__{adapter: adapter, config: config}, path, content) do
    adapter.put(path, content, config)
  end

  def get(%__MODULE__{adapter: adapter, config: config}, path) do
    adapter.get(path, config)
  end

  def delete(%__MODULE__{adapter: adapter, config: config}, path) do
    adapter.delete(path, config)
  end

  def exists?(%__MODULE__{adapter: adapter, config: config}, path) do
    adapter.exists?(path, config)
  end

  def url(%__MODULE__{adapter: adapter, config: config}, path, opts \\ []) do
    adapter.url(path, Keyword.merge(config, opts))
  end
end
