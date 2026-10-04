defmodule PhxMediaLibrary.Pipeline do
  @moduledoc """
  The steps that derive everything else from a media item's original file:
  metadata, the served WebP, responsive variants and conversions, plus
  dropping the original under WebP `keep_original: false`.

  Uploads (`PhxMediaLibrary.MediaAdder`) run these steps on the file just
  uploaded; repairs (the mix tasks) run the same steps on stored media. Each
  step resolves its settings through `PhxMediaLibrary.Model`, so an upload
  and a later repair produce the same result.

  ## Common options

    * `:model` — the model struct or module. Uploads pass it; otherwise the
      model is found from the media's `mediable_type` via
      `PhxMediaLibrary.ModelRegistry`.
    * `:source` — a local path to the original. Uploads pass the uploaded
      temp file; otherwise the original is read from storage (fetched into a
      temporary file for S3, see `PhxMediaLibrary.LocalSource`).

  Steps return `{:ok, media}` (or `:ok`), `{:skip, reason}` when the step
  doesn't apply to this media, or `{:error, reason}`.
  """

  alias PhxMediaLibrary.{
    Config,
    Conversions,
    LocalSource,
    Media,
    MetadataExtractor,
    Model,
    PathGenerator,
    ResponsiveImages,
    StorageWrapper,
    Webp
  }

  @typedoc "The outcome of a step."
  @type result :: {:ok, Media.t()} | {:skip, atom()} | {:error, term()}

  @doc """
  Extract metadata (dimensions, EXIF, ...) from the original and store it.

  Existing metadata is kept when nothing can be extracted, and
  `"original_file_name"` is always kept.

  ## Examples

      {:ok, media} = PhxMediaLibrary.Pipeline.metadata(media)

  """
  @spec metadata(Media.t(), keyword()) :: result()
  def metadata(%Media{} = media, opts \\ []) do
    with_source(media, opts, fn path ->
      case MetadataExtractor.extract_metadata(path, media.mime_type) do
        {:ok, metadata} when map_size(metadata) > 0 ->
          original = Map.take(media.metadata || %{}, ["original_file_name"])
          update(media, metadata: Map.merge(metadata, original))

        {:ok, _empty} ->
          {:error, :metadata_unavailable}
      end
    end)
  end

  @doc """
  Generate the served WebP from the original, using the collection's WebP
  settings.

  ## Examples

      {:ok, media} = PhxMediaLibrary.Pipeline.webp(media)
      {:skip, :disabled} = PhxMediaLibrary.Pipeline.webp(media_in_collection_without_webp)

  """
  @spec webp(Media.t(), keyword()) :: result()
  def webp(%Media{} = media, opts \\ []) do
    settings = Model.webp_settings(target(media, opts), media.collection_name)

    cond do
      not Keyword.get(settings, :enabled, false) ->
        {:skip, :disabled}

      not Webp.convertible?(media.mime_type) ->
        {:skip, :not_convertible}

      true ->
        storage = Config.storage_adapter(media.disk)
        original = PathGenerator.relative_path(media, nil)
        with_source(media, opts, &Webp.encode(media, &1, settings, storage, original))
    end
  end

  @doc """
  Generate responsive variants with the collection's widths, and store them
  alongside what `responsive_images` already holds (blurhash, poster, ...).

  Variants of the original are made only for collections that opt in (see
  `PhxMediaLibrary.Model.responsive?/3`); variants of conversions follow
  `PhxMediaLibrary.Model.conversion_responsive?/2`. A failure for the
  original fails the step; a failure for a conversion is skipped.

  ## Options

    * `:of` — what to generate variants of: `nil` for the original and/or
      conversion names. Default `[nil]`.
    * `:requested` — `true` when the caller asked for responsive images
      explicitly (`with_responsive_images/1`), even if the collection
      doesn't opt in.

  ## Examples

      {:ok, media} = PhxMediaLibrary.Pipeline.responsive(media, of: [nil, :thumb])

  """
  @spec responsive(Media.t(), keyword()) :: result()
  def responsive(%Media{} = media, opts \\ []) do
    target = target(media, opts)

    requested? = Keyword.get(opts, :requested, false)

    case Enum.filter(
           Keyword.get(opts, :of, [nil]),
           &responsive_for?(target, media, &1, requested?)
         ) do
      [] ->
        {:skip, :disabled}

      sources ->
        widths = Model.responsive_settings(target, media.collection_name)[:widths]

        with {:ok, data} <- generate_variants(media, sources, widths) do
          update(media, responsive_images: Map.merge(media.responsive_images || %{}, data))
        end
    end
  end

  defp responsive_for?(target, media, nil, requested?),
    do: Model.responsive?(target, media.collection_name, requested?)

  defp responsive_for?(target, media, _conversion, _requested?),
    do: Model.conversion_responsive?(target, media.collection_name)

  defp generate_variants(media, sources, widths) do
    Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, acc} ->
      case {source, ResponsiveImages.generate(media, source, widths: widths)} do
        {_, {:ok, data}} -> {:cont, {:ok, Map.merge(acc, data)}}
        {nil, {:error, _} = error} -> {:halt, error}
        {_conversion, {:error, _}} -> {:cont, {:ok, acc}}
      end
    end)
  end

  @doc """
  Run the collection's conversions synchronously.

  ## Options

    * `:only` — conversion names to run (atoms or strings); default all

  ## Examples

      :ok = PhxMediaLibrary.Pipeline.conversions(media, only: [:thumb])

  """
  @spec conversions(Media.t(), keyword()) :: :ok | {:skip, atom()} | {:error, term()}
  def conversions(%Media{} = media, opts \\ []) do
    only = opts |> Keyword.get(:only, []) |> Enum.map(&to_string/1)

    target(media, opts)
    |> Model.conversions(media.collection_name)
    |> Enum.filter(&(only == [] or to_string(&1.name) in only))
    |> case do
      [] -> {:skip, :no_conversions}
      conversions -> Conversions.process(media, conversions)
    end
  end

  @doc """
  Delete the original of media that serves a WebP, when the collection says
  `keep_original: false`. The record is unchanged.

  ## Options

    * `:dry_run` — report what would happen without deleting

  ## Examples

      :ok = PhxMediaLibrary.Pipeline.drop_original(media)
      {:skip, :keep_original} = PhxMediaLibrary.Pipeline.drop_original(media_keeping_originals)

  """
  @spec drop_original(Media.t(), keyword()) :: :ok | {:skip, atom()} | {:error, term()}
  def drop_original(%Media{} = media, opts \\ []) do
    settings = Model.webp_settings(target(media, opts), media.collection_name)

    cond do
      Keyword.get(settings, :keep_original, true) -> {:skip, :keep_original}
      not webp_served?(media) -> {:skip, :no_webp}
      not original_exists?(media) -> {:skip, :already_gone}
      Keyword.get(opts, :dry_run, false) -> :ok
      true -> drop(media)
    end
  end

  defp original_exists?(media) do
    media.disk
    |> Config.storage_adapter()
    |> StorageWrapper.exists?(PathGenerator.relative_path(media, nil))
  end

  defp drop(media) do
    case Webp.drop_original(media) do
      # The WebP *is* the original path; nothing to drop.
      :skip -> {:skip, :no_webp}
      result -> result
    end
  end

  @doc """
  Whether the media serves a WebP derivative.

  ## Examples

      PhxMediaLibrary.Pipeline.webp_served?(media)
      #=> true

  """
  @spec webp_served?(Media.t()) :: boolean()
  def webp_served?(%Media{custom_properties: %{"webp" => webp}}) when is_binary(webp), do: true
  def webp_served?(%Media{}), do: false

  defp target(media, opts), do: Keyword.get(opts, :model) || media

  defp with_source(media, opts, fun) do
    case Keyword.fetch(opts, :source) do
      {:ok, path} -> fun.(path)
      :error -> LocalSource.with_path(media, nil, fun)
    end
  end

  defp update(media, changes) do
    media
    |> Ecto.Changeset.change(changes)
    |> Config.repo().update()
  end
end
