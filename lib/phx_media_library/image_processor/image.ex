defmodule PhxMediaLibrary.ImageProcessor.Image do
  @moduledoc """
  Image processor implementation using the `Image` library.

  The `Image` library provides a high-level API on top of libvips,
  offering excellent performance and memory efficiency.
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

    save_opts =
      if quality do
        [quality: quality]
      else
        []
      end

    case format do
      :jpg -> Image.write(image, path, suffix: ".jpg", quality: quality || 85)
      :jpeg -> Image.write(image, path, suffix: ".jpg", quality: quality || 85)
      :png -> Image.write(image, path, suffix: ".png")
      :webp -> Image.write(image, path, suffix: ".webp", quality: quality || 80)
      _ -> Image.write(image, path, save_opts)
    end
  end

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

  defp maybe_resize(image, %{width: w, height: h, fit: fit}) do
    case fit do
      :contain ->
        Image.thumbnail(image, w || h, height: h, fit: :contain)

      :cover ->
        Image.thumbnail(image, w || h, height: h, fit: :cover)

      :fill ->
        Image.thumbnail(image, w || h, height: h, fit: :fill)

      :crop ->
        Image.thumbnail(image, w || h, height: h, fit: :cover, crop: :center)

      _ ->
        Image.thumbnail(image, w || h, height: h)
    end
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
