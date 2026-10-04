defmodule PhxMediaLibrary.Avif do
  @moduledoc """
  AVIF for media originals (0.9), opt-in with `avif:` globally or per
  collection.

  Called through `PhxMediaLibrary.Pipeline.avif/2`. The AVIF is stored beside
  the original (`…/name.avif`), recorded in `custom_properties["avif"]`, and
  has the size of the served file: fitted inside WebP's `max_dimension` when
  WebP is on.
  """

  alias PhxMediaLibrary.{Config, ImageProcessor, Webp}

  require Logger

  @logged_key {__MODULE__, :unsupported_logged}

  @doc """
  Whether a MIME type can be transcoded to AVIF: what WebP converts, and
  WebP itself.

  ## Examples

      iex> PhxMediaLibrary.Avif.convertible?("image/webp")
      true

      iex> PhxMediaLibrary.Avif.convertible?("image/svg+xml")
      false

  """
  @spec convertible?(String.t() | nil) :: boolean()
  def convertible?("image/webp"), do: true
  def convertible?(mime), do: Webp.convertible?(mime)

  @doc """
  Whether the configured image processor can write AVIF.

  ## Examples

      PhxMediaLibrary.Avif.supported?()
      #=> true

  """
  @spec supported?() :: boolean()
  def supported?, do: ImageProcessor.supports_format?(Config.image_processor(), :avif)

  @doc """
  Log, once per node, that AVIF is on but the image processor can't write
  it, so uploads go on without AVIF.
  """
  @spec log_unsupported_once() :: :ok
  def log_unsupported_once do
    unless :persistent_term.get(@logged_key, false) do
      :persistent_term.put(@logged_key, true)

      Logger.warning(
        "[PhxMediaLibrary] AVIF is enabled, but the image processor can't write AVIF " <>
          "(libvips needs AVIF support through libheif); files are stored without it"
      )
    end

    :ok
  end

  @doc """
  Transcode `source_path` (a local file) to AVIF beside the original at
  `orig_storage_path`, and record it in `custom_properties["avif"]`.
  `settings` carries `:quality` and `:max_dimension`.

  ## Examples

      {:ok, media} = Avif.encode(media, "/tmp/photo.jpg", [quality: nil], storage, "posts/1/u/photo.jpg")

  """
  @spec encode(map(), String.t(), keyword(), term(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def encode(media, source_path, settings, storage, orig_storage_path) do
    avif_path = Path.rootname(orig_storage_path) <> ".avif"

    case Webp.transcode(source_path, :avif, settings, storage, avif_path) do
      {:ok, _dims} ->
        props = Map.put(media.custom_properties || %{}, "avif", avif_path)
        media |> Ecto.Changeset.change(custom_properties: props) |> Config.repo().update()

      {:error, reason} = error ->
        Logger.warning(
          "[PhxMediaLibrary] AVIF generation failed for media #{inspect(media.id)}: " <>
            inspect(reason)
        )

        error
    end
  end
end
