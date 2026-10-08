defmodule PhxMediaLibrary.Conversion do
  @moduledoc """
  Represents an image conversion configuration.

  Conversions define how to transform images (resize, crop, etc.)
  and can be limited to specific collections. Declare them in your schema:

      media_conversions do
        convert :thumb, width: 150, height: 150, fit: :cover
        convert :preview, width: 800, quality: 85
        convert :og, width: 1200, height: 630, fit: :cover, format: :jpg, collections: [:images]
        convert :card, width: 600, formats: [avif: [quality: 50], webp: [quality: 80]]
      end
  """

  defstruct [
    :name,
    :width,
    :height,
    :fit,
    :quality,
    :format,
    :formats,
    :collections,
    :queued
  ]

  @type fit :: :contain | :cover | :fill | :crop
  @type format :: :jpg | :png | :webp | :avif | :original

  @type t :: %__MODULE__{
          name: atom(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          fit: fit(),
          quality: 1..100 | nil,
          format: format() | nil,
          formats: PhxMediaLibrary.Config.formats() | nil,
          collections: [atom()],
          queued: boolean()
        }

  @doc """
  Create a new conversion configuration.

  ## Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - Resize strategy (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - Output quality for JPEG/WebP (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`, `:avif`, `:original`); without it, WebP (never AVIF unless asked)
  - `:formats` - Output formats in priority order, with options:
    `[avif: [quality: 50], webp: []]`; wins over the collection's. `format: x`
    is `formats: [x]`. See `PhxMediaLibrary.Model.formats/4`
  - `:collections` - Only apply to these collections (default: all)
  - `:queued` - Process asynchronously (default: true)

  """
  @spec new(atom(), keyword()) :: t()
  def new(name, opts) do
    %__MODULE__{
      name: name,
      width: Keyword.get(opts, :width),
      height: Keyword.get(opts, :height),
      fit: Keyword.get(opts, :fit, :contain),
      quality: Keyword.get(opts, :quality),
      format: Keyword.get(opts, :format),
      formats: formats(name, opts),
      collections: Keyword.get(opts, :collections, []),
      queued: Keyword.get(opts, :queued, true)
    }
  end

  defp formats(name, opts) do
    value =
      case {Keyword.fetch(opts, :formats), Keyword.fetch(opts, :format)} do
        {{:ok, _}, {:ok, _}} -> {:error, "set format: or formats:, not both"}
        {{:ok, formats}, :error} -> PhxMediaLibrary.Config.normalize_formats(formats)
        {:error, {:ok, format}} -> PhxMediaLibrary.Config.normalize_formats([format])
        {:error, :error} -> {:ok, nil}
      end

    case value do
      {:ok, formats} -> formats
      {:error, message} -> raise ArgumentError, "conversion #{inspect(name)}: " <> message
    end
  end
end
