defmodule PhxMediaLibrary.ImageProcessor do
  @moduledoc """
  Behaviour for image processing adapters.

  The default implementation uses the `Image` library (libvips).
  """

  alias PhxMediaLibrary.Conversion

  @type image :: any()

  @doc "Open an image from a file path."
  @callback open(path :: String.t()) :: {:ok, image()} | {:error, term()}

  @doc "Apply a conversion to an image."
  @callback apply_conversion(image(), Conversion.t()) :: {:ok, image()} | {:error, term()}

  @doc "Save an image to a file path."
  @callback save(image(), path :: String.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc "Get image dimensions."
  @callback dimensions(image()) :: {:ok, {width :: integer(), height :: integer()}} | {:error, term()}

  @doc "Generate a tiny placeholder (base64 encoded)."
  @callback tiny_placeholder(image()) :: {:ok, String.t()} | {:error, term()}
end
