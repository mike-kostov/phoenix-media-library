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

  @doc "Save an image to a file path. Returns the image for chaining."
  @callback save(image(), path :: String.t(), opts :: keyword()) ::
              {:ok, image()} | {:error, term()}

  @doc "Get image dimensions."
  @callback dimensions(image()) ::
              {:ok, {width :: integer(), height :: integer()}} | {:error, term()}

  @doc """
  Generate a tiny placeholder: a data URI of a few pixels' wide image,
  without metadata, with its `:width` and `:height`.
  """
  @callback tiny_placeholder(image()) ::
              {:ok, %{data_uri: String.t(), width: pos_integer(), height: pos_integer()}}
              | {:error, term()}

  @doc "The image's average color as `#rrggbb`. Optional: without it, `:color` placeholders are skipped."
  @callback average_color(image()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Whether the processor can save images in `format` (e.g. `:avif`, which
  needs a libvips built with AVIF support). Optional: processors without it
  are assumed to support every format.
  """
  @callback supports_format?(format :: atom()) :: boolean()

  @optional_callbacks [supports_format?: 1, average_color: 1]

  @doc """
  Whether `processor` can save images in `format`; `true` for processors
  that don't implement `c:supports_format?/1`.

  ## Examples

      PhxMediaLibrary.ImageProcessor.supports_format?(PhxMediaLibrary.ImageProcessor.Image, :avif)
      #=> true

  """
  @spec supports_format?(module(), atom()) :: boolean()
  def supports_format?(processor, format) do
    Code.ensure_loaded(processor)

    if function_exported?(processor, :supports_format?, 1),
      do: processor.supports_format?(format),
      else: true
  end
end
