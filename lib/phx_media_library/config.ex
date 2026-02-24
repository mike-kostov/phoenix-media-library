defmodule PhxMediaLibrary.Config do
  @moduledoc """
  Configuration helpers for PhxMediaLibrary.
  """

  @doc """
  Get the configured Ecto repo.
  """
  def repo do
    Application.fetch_env!(:phx_media_library, :repo)
  end

  @doc """
  Get the default storage disk name.
  """
  def default_disk do
    Application.get_env(:phx_media_library, :default_disk, :local)
  end

  @doc """
  Get configuration for a specific disk.
  """
  def disk_config(disk_name) do
    disks = Application.get_env(:phx_media_library, :disks, default_disks())
    # Convert string disk names to atoms for keyword lookup
    disk_key = if is_binary(disk_name), do: String.to_existing_atom(disk_name), else: disk_name
    Keyword.get(disks, disk_key) || raise "Unknown disk: #{inspect(disk_name)}"
  end

  @doc """
  Get the storage adapter module for a disk.
  """
  def storage_adapter(disk_name) do
    config = disk_config(disk_name)
    adapter = Keyword.fetch!(config, :adapter)

    # Return a wrapper that passes config to each call
    %PhxMediaLibrary.StorageWrapper{
      adapter: adapter,
      config: config
    }
  end

  @doc """
  Get the async processor module.
  """
  def async_processor do
    Application.get_env(:phx_media_library, :async_processor, PhxMediaLibrary.AsyncProcessor.Task)
  end

  @doc """
  Get the image processor module.
  """
  def image_processor do
    Application.get_env(
      :phx_media_library,
      :image_processor,
      PhxMediaLibrary.ImageProcessor.Image
    )
  end

  @doc """
  Get responsive images configuration.
  """
  def responsive_images_config do
    Application.get_env(:phx_media_library, :responsive_images, [])
  end

  @doc """
  Check if responsive images are enabled.
  """
  def responsive_images_enabled? do
    Keyword.get(responsive_images_config(), :enabled, true)
  end

  @doc """
  Get the widths to generate for responsive images.
  """
  def responsive_image_widths do
    Keyword.get(responsive_images_config(), :widths, [320, 640, 960, 1280, 1920])
  end

  @doc """
  Check if tiny placeholders should be generated.
  """
  def tiny_placeholders_enabled? do
    Keyword.get(responsive_images_config(), :tiny_placeholder, true)
  end

  # Default disk configuration
  defp default_disks do
    [
      local: [
        adapter: PhxMediaLibrary.Storage.Disk,
        root: "priv/static/uploads",
        base_url: "/uploads"
      ]
    ]
  end
end
