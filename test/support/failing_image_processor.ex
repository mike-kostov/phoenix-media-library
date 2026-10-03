defmodule PhxMediaLibrary.FailingImageProcessor do
  @moduledoc """
  Test image processor: behaves like `PhxMediaLibrary.ImageProcessor.Image`,
  except that any conversion named `:broken` fails.
  """

  @behaviour PhxMediaLibrary.ImageProcessor

  alias PhxMediaLibrary.ImageProcessor.Image, as: Real

  @impl true
  def open(path), do: Real.open(path)

  @impl true
  def apply_conversion(_image, %{name: :broken}), do: {:error, :broken_on_purpose}
  def apply_conversion(image, conversion), do: Real.apply_conversion(image, conversion)

  @impl true
  def save(image, path, opts), do: Real.save(image, path, opts)

  @impl true
  def dimensions(image), do: Real.dimensions(image)

  @impl true
  def tiny_placeholder(image), do: Real.tiny_placeholder(image)
end
