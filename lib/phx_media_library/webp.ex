defmodule PhxMediaLibrary.Webp do
  @moduledoc """
  WebP transcoding for media originals (0.8).

  Called through `PhxMediaLibrary.Pipeline.webp/2`, which resolves the
  collection's settings, both on add and for re-generation. Encapsulates the
  encode + store + record.
  """

  alias PhxMediaLibrary.{Config, StorageWrapper}
  require Logger

  # Raster formats libvips can decode into WebP. Excludes SVG (vector) and WebP
  # (already WebP). image/heic + image/heif cover iPhone uploads.
  @convertible ~w(image/jpeg image/png image/heic image/heif image/tiff image/bmp image/gif)

  @doc "Whether a MIME type can be transcoded to WebP."
  @spec convertible?(String.t()) :: boolean()
  def convertible?(mime) when is_binary(mime), do: mime in @convertible
  def convertible?(_), do: false

  @doc """
  Transcode `source_path` (a local file) to WebP and store it beside the original
  at `orig_storage_path` (`…/name.webp`), recording it in
  `custom_properties["webp"]` so URL helpers serve it. `settings` carries
  `:quality` and `:max_dimension`.

  With `:max_dimension` set, the WebP is resized to fit inside a square of that
  many pixels (aspect preserved, never upscaled) and its final dimensions are
  recorded in `custom_properties["webp_width"]` / `["webp_height"]` so
  responsive generation knows the served size.

  The source file is always kept here — for `keep_original: false` the original
  is removed later by the add flow, **after** conversions run (so conversions
  still derive from the original and nothing is deleted before them).

  Returns the updated media, or the media unchanged on any processor/storage
  error (graceful degradation — the original is still served). Use
  `encode/5` to tell the two apart.
  """
  @spec generate(map(), String.t(), keyword(), term(), String.t()) :: map()
  def generate(media, source_path, settings, storage, orig_storage_path) do
    case encode(media, source_path, settings, storage, orig_storage_path) do
      {:ok, media} -> media
      {:error, _reason} -> media
    end
  end

  @doc """
  Same as `generate/5`, but returns `{:ok, media}` or `{:error, reason}`
  (logged as a warning) so callers can report failures.

  ## Examples

      {:ok, media} = Webp.encode(media, "/tmp/photo.jpg", [quality: 82], storage, "posts/1/u/photo.jpg")

  """
  @spec encode(map(), String.t(), keyword(), term(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def encode(media, source_path, settings, storage, orig_storage_path) do
    settings = Keyword.put_new(settings, :quality, 82)
    webp_path = Path.rootname(orig_storage_path) <> ".webp"

    case transcode(source_path, :webp, settings, storage, webp_path) do
      {:ok, dims} ->
        props =
          (media.custom_properties || %{})
          |> Map.put("webp", webp_path)
          |> put_dims(dims)

        media |> Ecto.Changeset.change(custom_properties: props) |> Config.repo().update()

      {:error, reason} = error ->
        Logger.warning(
          "[webp] generation failed for media #{inspect(media.id)}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Transcode `source_path` (a local file) to `format` and store it at
  `storage_path`. `settings` carries `:quality` (`nil`: the processor's
  default) and `:max_dimension`. Returns the stored image's dimensions when
  `:max_dimension` is set, else `nil`. Shared by WebP and AVIF.

  ## Examples

      {:ok, {1200, 800}} =
        Webp.transcode("/tmp/photo.jpg", :avif, [max_dimension: 1200], storage, "posts/1/u/photo.avif")

  """
  @spec transcode(String.t(), atom(), keyword(), term(), String.t()) ::
          {:ok, {pos_integer(), pos_integer()} | nil} | {:error, term()}
  def transcode(source_path, format, settings, storage, storage_path) do
    processor = Config.image_processor()
    save_opts = Enum.reject([format: format, quality: settings[:quality]], &is_nil(elem(&1, 1)))
    tmp = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}.#{format}")

    result =
      with {:ok, image} <- processor.open(source_path),
           {:ok, {image, dims}} <-
             fit_within(image, Keyword.get(settings, :max_dimension), processor),
           # libvips picks the encoder by the destination extension, so the
           # temp path (not just `format:`) carries the format's extension.
           {:ok, _} <- processor.save(image, tmp, save_opts),
           {:ok, content} <- File.read(tmp),
           :ok <- StorageWrapper.put(storage, storage_path, content) do
        {:ok, dims}
      end

    _ = File.rm(tmp)
    result
  end

  @doc """
  Delete the source file of a media that already serves a WebP, for the
  `keep_original: false` policy applied after the fact (`mix
  phx_media_library.drop_originals`). The record is untouched: `file_name`
  keeps naming the absent source, exactly as an add with `keep_original: false`
  leaves it. Returns `:skip` when there is no WebP to fall back on.
  """
  @spec drop_original(map()) :: :ok | :skip | {:error, term()}
  def drop_original(%{custom_properties: %{"webp" => webp}} = media) when is_binary(webp) do
    original = PhxMediaLibrary.PathGenerator.relative_path(media, nil)

    if original == webp do
      :skip
    else
      StorageWrapper.delete(Config.storage_adapter(media.disk), original)
    end
  end

  def drop_original(_media), do: :skip

  @doc """
  Dimensions of a `width` x `height` image scaled to fit inside a
  `max_dimension` square, aspect preserved. Never upscales.

      iex> PhxMediaLibrary.Webp.fit_dimensions({3000, 2000}, 1200)
      {1200, 800}
      iex> PhxMediaLibrary.Webp.fit_dimensions({600, 400}, 1200)
      {600, 400}
      iex> PhxMediaLibrary.Webp.fit_dimensions({600, 400}, nil)
      {600, 400}
  """
  @spec fit_dimensions({pos_integer(), pos_integer()}, pos_integer() | nil) ::
          {pos_integer(), pos_integer()}
  def fit_dimensions({w, h}, nil), do: {w, h}

  def fit_dimensions({w, h}, max) when is_integer(max) and max > 0 do
    longest = max(w, h)

    if longest <= max do
      {w, h}
    else
      scale = max / longest
      {max(round(w * scale), 1), max(round(h * scale), 1)}
    end
  end

  # No cap: dimensions are unknown here and left unrecorded (`nil`).
  defp fit_within(image, nil, _processor), do: {:ok, {image, nil}}

  defp fit_within(image, max, processor) do
    with {:ok, {w, h}} <- processor.dimensions(image) do
      case fit_dimensions({w, h}, max) do
        {^w, ^h} -> {:ok, {image, {w, h}}}
        {tw, th} -> resize(image, {tw, th}, processor)
      end
    end
  end

  defp resize(image, {tw, th}, processor) do
    conversion = %PhxMediaLibrary.Conversion{name: :webp, width: tw, height: th, fit: :contain}

    with {:ok, resized} <- processor.apply_conversion(image, conversion) do
      {:ok, {resized, {tw, th}}}
    end
  end

  defp put_dims(props, nil), do: Map.drop(props, ["webp_width", "webp_height"])
  defp put_dims(props, {w, h}), do: props |> Map.put("webp_width", w) |> Map.put("webp_height", h)
end
