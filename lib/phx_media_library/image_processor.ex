defmodule PhxMediaLibrary.ImageProcessor do
  @moduledoc """
  Behaviour for image processing adapters.

  The default implementation uses the `Image` library (libvips). Another
  backend implements the callbacks and is set in config:

      config :phx_media_library, image_processor: MyApp.VipsProcessor

  The optional callbacks (`supports_format?/1`, `average_color/1`,
  `has_alpha?/1`, `tiny_placeholder/2`) unlock AVIF detection, `:color`
  placeholders and transparency handling; without them the library falls
  back to safe defaults.
  """

  require Logger

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

  @doc """
  Like `c:tiny_placeholder/1`, `size` pixels on its longest side. Optional: without it,
  `c:tiny_placeholder/1` is used whatever the size setting.
  """
  @callback tiny_placeholder(image(), size :: pos_integer()) ::
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

  @doc """
  Whether the image has an alpha channel. Optional: without it, images are
  treated as opaque.
  """
  @callback has_alpha?(image()) :: boolean()

  @optional_callbacks [supports_format?: 1, average_color: 1, has_alpha?: 1, tiny_placeholder: 2]

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

  @logged_key {__MODULE__, :unavailable_logged}

  @doc """
  Whether images can be processed: `false` in apps without the `:image`
  library, where `PhxMediaLibrary.ImageProcessor.Null` stands in and images
  are stored as uploaded.

  ## Examples

      PhxMediaLibrary.ImageProcessor.available?()
      #=> true

  """
  @spec available?() :: boolean()
  def available?,
    do: PhxMediaLibrary.Config.image_processor() != PhxMediaLibrary.ImageProcessor.Null

  @doc false
  # Once per node: an image arrived and nothing can process it.
  @spec log_unavailable_once() :: :ok
  def log_unavailable_once do
    unless :persistent_term.get(@logged_key, false) do
      :persistent_term.put(@logged_key, true)

      Logger.warning(
        "[PhxMediaLibrary] images are stored as uploaded: without the :image library " <>
          "(libvips) there are no WebP, AVIF, responsive sizes, conversions or " <>
          ~s(placeholders. Add {:image, "~> 0.63"} to your deps.)
      )
    end

    :ok
  end
end
