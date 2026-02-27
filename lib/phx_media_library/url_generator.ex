defmodule PhxMediaLibrary.UrlGenerator do
  @moduledoc """
  Generates URLs for media files.
  """

  alias PhxMediaLibrary.{Config, Media, PathGenerator, StorageWrapper}

  @doc """
  Generate a URL for a media item.
  """
  @spec url(Media.t(), atom() | nil, keyword()) :: String.t()
  def url(%Media{disk: disk} = media, conversion \\ nil, opts \\ []) do
    storage = Config.storage_adapter(disk)
    relative_path = PathGenerator.relative_path(media, conversion)

    StorageWrapper.url(storage, relative_path, opts)
  end

  @doc """
  Generate a URL for a specific path (used for responsive images).
  """
  @spec url_for_path(Media.t(), String.t(), keyword()) :: String.t()
  def url_for_path(%Media{disk: disk}, path, opts \\ []) do
    storage = Config.storage_adapter(disk)
    StorageWrapper.url(storage, path, opts)
  end
end
