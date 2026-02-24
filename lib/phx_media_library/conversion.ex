defmodule PhxMediaLibrary.Conversion do
  @moduledoc """
  Represents an image conversion configuration.

  Conversions define how to transform images (resize, crop, etc.)
  and can be limited to specific collections.
  """

  defstruct [
    :name,
    :width,
    :height,
    :fit,
    :quality,
    :format,
    :collections,
    :queued
  ]

  @type fit :: :contain | :cover | :fill | :crop
  @type format :: :jpg | :png | :webp | :original

  @type t :: %__MODULE__{
          name: atom(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          fit: fit(),
          quality: 1..100 | nil,
          format: format() | nil,
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
  - `:format` - Output format (`:jpg`, `:png`, `:webp`, `:original`)
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
      collections: Keyword.get(opts, :collections, []),
      queued: Keyword.get(opts, :queued, true)
    }
  end
end
