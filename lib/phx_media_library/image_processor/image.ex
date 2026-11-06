if Code.ensure_loaded?(Image) do
  defmodule PhxMediaLibrary.ImageProcessor.Image do
    @moduledoc """
    Image processor implementation using the `Image` library.

    The `Image` library provides a high-level API on top of libvips,
    offering excellent performance and memory efficiency.

    This module is only compiled when the `:image` dependency is available.
    If `:image` is not installed, `PhxMediaLibrary.ImageProcessor.Null` is
    used as the default processor instead.
    """

    @behaviour PhxMediaLibrary.ImageProcessor

    alias Vix.Vips.Foreign

    @impl true
    def open(path) do
      Image.open(path)
    end

    @impl true
    def apply_conversion(image, %PhxMediaLibrary.Conversion{} = conversion) do
      image
      |> maybe_resize(conversion)
      |> maybe_set_quality(conversion)
    end

    @impl true
    def save(image, path, opts \\ []) do
      format = opts[:format] || format_from_path(path)
      quality = opts[:quality]
      write_opts = write_opts_for_format(format, quality)

      Image.write(image, path, write_opts)
    end

    defp write_opts_for_format(format, quality) when format in [:jpg, :jpeg] do
      [suffix: ".jpg", quality: quality || 85]
    end

    defp write_opts_for_format(:png, _quality), do: [suffix: ".png"]

    defp write_opts_for_format(:webp, quality) do
      [suffix: ".webp", quality: quality || 80]
    end

    defp write_opts_for_format(_format, nil), do: []
    defp write_opts_for_format(_format, quality), do: [quality: quality]

    # libvips picks a saver by extension; AVIF needs one built with libheif.
    @impl true
    def supports_format?(format) do
      match?({:ok, _saver}, Foreign.find_save("probe.#{format}"))
    end

    @impl true
    def dimensions(image) do
      {:ok, {Image.width(image), Image.height(image)}}
    end

    @impl true
    def tiny_placeholder(image), do: tiny_placeholder(image, 32)

    # A WebP without EXIF or color profile, `size` on its longest side
    # (Image.thumbnail/2): at 32px, about 260 bytes on
    # product photos (docs/ideas/placeholders.md).
    @impl true
    def tiny_placeholder(image, size) do
      with {:ok, tiny} <- Image.thumbnail(image, size),
           {:ok, buffer} <- Image.write(tiny, :memory, suffix: ".webp", strip_metadata: true) do
        {:ok,
         %{
           data_uri: "data:image/webp;base64," <> Base.encode64(buffer),
           width: Image.width(tiny),
           height: Image.height(tiny)
         }}
      end
    end

    @impl true
    def has_alpha?(image), do: Image.has_alpha?(image)

    @impl true
    def average_color(image) do
      # Image.average/1 weights by alpha (transparent pixels don't count)
      # and returns one value per color band.
      case Image.average(image) do
        {:ok, [gray]} -> {:ok, hex_color([gray, gray, gray])}
        {:ok, [r, g, b | _]} -> {:ok, hex_color([r, g, b])}
        {:error, _} = error -> error
      end
    end

    defp hex_color(rgb), do: "#" <> Enum.map_join(rgb, &hex_byte/1)

    defp hex_byte(value) do
      value
      |> round()
      |> max(0)
      |> min(255)
      |> Integer.to_string(16)
      |> String.pad_leading(2, "0")
      |> String.downcase()
    end

    # Private functions

    # libvips' documented way to constrain one side only: make the other huge.
    @unbounded 10_000_000

    defp maybe_resize(image, %{width: nil, height: nil}), do: {:ok, image}

    # One side given: scale to it and keep the aspect ratio (`fit` needs a box).
    defp maybe_resize(image, %{width: w, height: nil}),
      do: Image.thumbnail(image, w, height: @unbounded)

    defp maybe_resize(image, %{width: nil, height: h}),
      do: Image.thumbnail(image, @unbounded, height: h)

    defp maybe_resize(image, %{width: w, height: h, fit: :crop}) do
      Image.thumbnail(image, w, height: h, fit: :cover, crop: :center)
    end

    defp maybe_resize(image, %{width: w, height: h, fit: fit})
         when fit in [:contain, :cover, :fill] do
      Image.thumbnail(image, w, height: h, fit: fit)
    end

    defp maybe_resize(image, %{width: w, height: h}) do
      Image.thumbnail(image, w, height: h)
    end

    defp maybe_set_quality({:ok, image}, %{quality: nil}), do: {:ok, image}
    defp maybe_set_quality({:ok, image}, %{quality: _quality}), do: {:ok, image}
    defp maybe_set_quality({:error, _} = error, _), do: error
    defp maybe_set_quality(image, _), do: {:ok, image}

    # Extensions come from filenames, so never turn them into atoms: unknown
    # ones would fill the atom table, which is never garbage collected.
    @formats %{
      "jpg" => :jpg,
      "jpeg" => :jpg,
      "png" => :png,
      "webp" => :webp,
      "avif" => :avif,
      "gif" => :gif,
      "tif" => :tiff,
      "tiff" => :tiff,
      "heic" => :heic,
      "heif" => :heif
    }

    defp format_from_path(path) do
      extension = path |> Path.extname() |> String.downcase() |> String.trim_leading(".")
      Map.get(@formats, extension, :unknown)
    end
  end
end
