defmodule PhxMediaLibrary.ImageProcessor.Null do
  @moduledoc """
  No-op image processor used when no image processing library is installed.

  This adapter allows PhxMediaLibrary to function for basic file storage
  (PDFs, documents, CSVs, etc.) without requiring libvips or any image
  processing dependency.

  All operations return `{:error, :no_image_processor}` with a clear
  message guiding the developer to install an image processing library.
  """

  @behaviour PhxMediaLibrary.ImageProcessor

  @error_message """
  No image processor is available. To use image conversions and responsive \
  images, add {:image, "~> 0.54"} to your dependencies and set:

      config :phx_media_library, image_processor: PhxMediaLibrary.ImageProcessor.Image

  If you only need file storage (PDFs, documents, etc.), no image processor \
  is required.\
  """

  @impl true
  @doc """
  Returns an error — no image processor is installed.
  """
  @spec open(String.t()) :: {:error, {:no_image_processor, String.t()}}
  def open(_path) do
    {:error, {:no_image_processor, @error_message}}
  end

  @impl true
  @doc """
  Returns an error — no image processor is installed.
  """
  @spec apply_conversion(any(), PhxMediaLibrary.Conversion.t()) ::
          {:error, {:no_image_processor, String.t()}}
  def apply_conversion(_image, _conversion) do
    {:error, {:no_image_processor, @error_message}}
  end

  @impl true
  @doc """
  Returns an error — no image processor is installed.
  """
  @spec save(any(), String.t(), keyword()) :: {:error, {:no_image_processor, String.t()}}
  def save(_image, _path, _opts \\ []) do
    {:error, {:no_image_processor, @error_message}}
  end

  @impl true
  @doc """
  Returns an error — no image processor is installed.
  """
  @spec dimensions(any()) :: {:error, {:no_image_processor, String.t()}}
  def dimensions(_image) do
    {:error, {:no_image_processor, @error_message}}
  end

  @impl true
  @doc """
  Returns an error — no image processor is installed.
  """
  @spec tiny_placeholder(any()) :: {:error, {:no_image_processor, String.t()}}
  def tiny_placeholder(_image) do
    {:error, {:no_image_processor, @error_message}}
  end
end
