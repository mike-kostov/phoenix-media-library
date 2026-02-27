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

    @impl true
    def dimensions(image) do
      {:ok, {Image.width(image), Image.height(image)}}
    end

    @impl true
    def tiny_placeholder(image) do
      # Generate a 32px wide tiny placeholder
      with {:ok, tiny} <- Image.thumbnail(image, 32),
           {:ok, buffer} <- Image.write(tiny, :memory, suffix: ".jpg", quality: 40) do
        base64 = Base.encode64(buffer)
        # Image.width/height return integers directly, not tuples
        width = Image.width(tiny)
        height = Image.height(tiny)

        # Return as data URI with dimensions
        {:ok,
         %{
           data_uri: "data:image/jpeg;base64,#{base64}",
           width: width,
           height: height
         }}
      end
    end

    # Private functions

    defp maybe_resize(image, %{width: nil, height: nil}), do: {:ok, image}

    defp maybe_resize(image, %{width: w, height: h, fit: :crop}) do
      Image.thumbnail(image, w || h, height: h, fit: :cover, crop: :center)
    end

    defp maybe_resize(image, %{width: w, height: h, fit: fit})
         when fit in [:contain, :cover, :fill] do
      Image.thumbnail(image, w || h, height: h, fit: fit)
    end

    defp maybe_resize(image, %{width: w, height: h}) do
      Image.thumbnail(image, w || h, height: h)
    end

    defp maybe_set_quality({:ok, image}, %{quality: nil}), do: {:ok, image}
    defp maybe_set_quality({:ok, image}, %{quality: _quality}), do: {:ok, image}
    defp maybe_set_quality({:error, _} = error, _), do: error
    defp maybe_set_quality(image, _), do: {:ok, image}

    defp format_from_path(path) do
      path
      |> Path.extname()
      |> String.downcase()
      |> String.trim_leading(".")
      |> String.to_atom()
    end
  end
end
