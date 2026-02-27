defmodule PhxMediaLibrary.PathGenerator do
  @moduledoc """
  Generates storage paths for media files.

  The default path structure is:
  `{mediable_type}/{mediable_id}/{uuid}/{conversion}/{filename}`
  """

  alias PhxMediaLibrary.{Config, Media}

  @doc """
  Generate a path for new media (before it has an ID).
  """
  def for_new_media(attrs) do
    parts = [
      attrs.mediable_type,
      attrs.mediable_id,
      attrs.uuid,
      attrs.file_name
    ]

    Path.join(parts)
  end

  @doc """
  Generate the relative storage path for a media item.
  """
  @spec relative_path(Media.t(), atom() | String.t() | nil) :: String.t()
  def relative_path(%Media{} = media, conversion \\ nil) do
    base_path =
      Path.join([
        media.mediable_type,
        media.mediable_id,
        media.uuid
      ])

    filename = conversion_filename(media, conversion)
    Path.join(base_path, filename)
  end

  @doc """
  Get the full filesystem path (for local storage).
  """
  @spec full_path(Media.t(), atom() | nil) :: String.t() | nil
  def full_path(%Media{disk: disk} = media, conversion) do
    storage = Config.storage_adapter(disk)
    relative = relative_path(media, conversion)

    # Ensure the adapter module is loaded before checking for the optional
    # path/2 callback. function_exported?/3 does not auto-load modules.
    Code.ensure_loaded(storage.adapter)

    if function_exported?(storage.adapter, :path, 2) do
      storage.adapter.path(relative, storage.config)
    else
      nil
    end
  end

  defp conversion_filename(%Media{file_name: file_name}, nil) do
    file_name
  end

  defp conversion_filename(%Media{file_name: file_name}, conversion) do
    ext = Path.extname(file_name)
    base = Path.rootname(file_name)
    "#{base}_#{conversion}#{ext}"
  end
end
