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
  Transcode `source_path` (a local file) to WebP, store it beside the original at
  `orig_storage_path` (`…/name.webp`), and update `media` per `settings`
  (`:quality`, `:keep_original`).

  Returns the updated media, or the original media unchanged on any
  processor/storage error (graceful degradation — the original is still served).
  """
  @spec generate(map(), String.t(), keyword(), term(), String.t()) :: map()
  def generate(media, source_path, settings, storage, orig_storage_path) do
    quality = Keyword.get(settings, :quality, 82)
    keep_original? = Keyword.get(settings, :keep_original, true)
    processor = Config.image_processor()
    webp_path = Path.rootname(orig_storage_path) <> ".webp"
    tmp = Path.join(System.tmp_dir!(), "#{media.uuid}-#{System.unique_integer([:positive])}.webp")

    result =
      with {:ok, image} <- processor.open(source_path),
           # save to a `.webp` path — libvips picks the encoder by the destination
           # extension, so the path (not just `format:`) must be `.webp`.
           {:ok, _} <- processor.save(image, tmp, format: :webp, quality: quality),
           {:ok, content} <- File.read(tmp),
           :ok <- StorageWrapper.put(storage, webp_path, content) do
        {:ok, webp_path, content}
      end

    _ = File.rm(tmp)

    case result do
      {:ok, wpath, content} ->
        apply_result(media, wpath, content, keep_original?, storage, orig_storage_path)

      other ->
        Logger.warning("[webp] generation failed for media #{inspect(media.id)}: #{inspect(other)}")
        media
    end
  end

  # keep_original: true — original stays as the primary file; WebP sibling is
  # recorded in custom_properties so URL helpers serve it.
  defp apply_result(media, webp_path, _content, true, _storage, _orig) do
    props = Map.put(media.custom_properties || %{}, "webp", webp_path)

    {:ok, media} =
      media |> Ecto.Changeset.change(custom_properties: props) |> Config.repo().update()

    media
  end

  # keep_original: false — replace the original with the WebP.
  defp apply_result(media, webp_path, content, false, storage, orig) do
    if orig != webp_path, do: StorageWrapper.delete(storage, orig)

    {:ok, media} =
      media
      |> Ecto.Changeset.change(
        file_name: Path.basename(webp_path),
        mime_type: "image/webp",
        size: byte_size(content),
        checksum: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      )
      |> Config.repo().update()

    media
  end
end
