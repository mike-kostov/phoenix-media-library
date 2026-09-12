defmodule PhxMediaLibrary.Webp do
  @moduledoc """
  WebP transcoding for media originals (0.8).

  Used both on add (`PhxMediaLibrary.MediaAdder`) and for bulk re-generation
  (`mix phx_media_library.regenerate`). Encapsulates the encode + store + record
  so the two call sites stay in sync.
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
  error (graceful degradation — the original is still served).
  """
  @spec generate(map(), String.t(), keyword(), term(), String.t()) :: map()
  def generate(media, source_path, settings, storage, orig_storage_path) do
    quality = Keyword.get(settings, :quality, 82)
    max_dimension = Keyword.get(settings, :max_dimension)
    processor = Config.image_processor()
    webp_path = Path.rootname(orig_storage_path) <> ".webp"
    tmp = Path.join(System.tmp_dir!(), "#{media.uuid}-#{System.unique_integer([:positive])}.webp")

    result =
      with {:ok, image} <- processor.open(source_path),
           {:ok, {image, dims}} <- fit_within(image, max_dimension, processor),
           # save to a `.webp` path — libvips picks the encoder by the destination
           # extension, so the path (not just `format:`) must be `.webp`.
           {:ok, _} <- processor.save(image, tmp, format: :webp, quality: quality),
           {:ok, content} <- File.read(tmp),
           :ok <- StorageWrapper.put(storage, webp_path, content) do
        {:ok, webp_path, dims}
      end

    _ = File.rm(tmp)

    case result do
      {:ok, wpath, dims} ->
        props =
          (media.custom_properties || %{})
          |> Map.put("webp", wpath)
          |> put_dims(dims)

        {:ok, media} =
          media |> Ecto.Changeset.change(custom_properties: props) |> Config.repo().update()

        media

      other ->
        Logger.warning(
          "[webp] generation failed for media #{inspect(media.id)}: #{inspect(other)}"
        )

        media
    end
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
        {^w, ^h} ->
          {:ok, {image, {w, h}}}

        {tw, th} ->
          conversion = %PhxMediaLibrary.Conversion{
            name: :webp,
            width: tw,
            height: th,
            fit: :contain
          }

          with {:ok, resized} <- processor.apply_conversion(image, conversion) do
            {:ok, {resized, {tw, th}}}
          end
      end
    end
  end

  defp put_dims(props, nil), do: Map.drop(props, ["webp_width", "webp_height"])
  defp put_dims(props, {w, h}), do: props |> Map.put("webp_width", w) |> Map.put("webp_height", h)
end
