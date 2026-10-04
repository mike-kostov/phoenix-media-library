defmodule PhxMediaLibrary.NoAvifImageProcessor do
  @moduledoc """
  Test image processor: behaves like `PhxMediaLibrary.ImageProcessor.Image`
  on a libvips built without AVIF support.
  """

  @behaviour PhxMediaLibrary.ImageProcessor

  alias PhxMediaLibrary.ImageProcessor.Image, as: Real

  @impl true
  def open(path), do: Real.open(path)

  @impl true
  def apply_conversion(image, conversion), do: Real.apply_conversion(image, conversion)

  @impl true
  def save(image, path, opts \\ []), do: Real.save(image, path, opts)

  @impl true
  def dimensions(image), do: Real.dimensions(image)

  @impl true
  def tiny_placeholder(image), do: Real.tiny_placeholder(image)

  @impl true
  def supports_format?(:avif), do: false
  def supports_format?(format), do: Real.supports_format?(format)
end
