defmodule PhxMediaLibrary.Conversions do
  @moduledoc """
  Runs a media item's conversions, then its placeholders. Async
  processors call it; so can your own jobs:

      PhxMediaLibrary.Conversions.process(media, PhxMediaLibrary.Model.conversions(media, media.collection_name))
  """

  alias PhxMediaLibrary.{
    Config,
    Conversion,
    DocumentRenderer,
    LocalSource,
    Media,
    Model,
    PathGenerator,
    Pipeline,
    ResponsiveImages,
    StorageWrapper,
    Telemetry
  }

  require Logger

  @doc """
  Process all conversions for a media item, then make its placeholders (see
  `PhxMediaLibrary.Pipeline.placeholder/2`). With no conversions, only the
  placeholders are made.

  The source is read from local disk, or fetched into a temporary file for
  storage without a local path (S3, memory). Conversions that succeed are
  recorded even when others fail.

  Returns `:ok` when every conversion succeeded, otherwise
  `{:error, {:conversions_failed, failures}}` (logged as a warning) so that
  job runners such as Oban retry.
  """
  @spec process(Media.t(), [Conversion.t()]) :: :ok | {:error, term()}
  def process(%Media{} = media, conversions) do
    # Re-read fresh: between enqueue and processing the media may have been
    # deleted or updated (a real race, and common with async tasks in tests).
    # Working from the current row avoids Ecto.StaleEntryError on the conversion
    # and responsive updates below.
    case Config.repo().get(Media, media.id) do
      nil ->
        Logger.debug(
          "[PhxMediaLibrary] media #{inspect(media.id)} no longer exists, skipping conversions"
        )

        :ok

      # The job's start is its one extra write; what it makes and how it
      # ended go into one final update (spec 02, C4 and F6).
      fresh ->
        with {:ok, media} <- start(fresh) do
          {changes, result} = run(media, conversions)
          finish(media, changes, result)
        end
    end
  end

  defp start(media) do
    case Media.save_changes(media,
           processing_started_at: now(),
           processing_finished_at: nil,
           processing_failed_at: nil,
           processing_error: nil
         ) do
      {:ok, media} -> {:ok, media}
      {:error, reason} -> {:error, {:record_update_failed, reason}}
    end
  end

  # What the job makes, as changes for the final update, and how it ended.
  # Files that aren't images (or PDFs with a renderer) have nothing to make;
  # placeholders alone never fail the job.
  defp run(media, conversions) do
    if DocumentRenderer.image_source?(media.mime_type) do
      case LocalSource.with_image(media, &run(media, conversions, &1)) do
        {changes, result} when is_list(changes) -> {changes, result}
        {:error, reason} -> unreadable(media, conversions, reason)
      end
    else
      {[], :ok}
    end
  end

  # Without conversions there is nothing to retry for: log it and finish.
  defp unreadable(media, [], reason) do
    Logger.warning(
      "[PhxMediaLibrary] placeholder failed for media #{inspect(media.id)}: #{inspect(reason)}"
    )

    {[], :ok}
  end

  defp unreadable(_media, _conversions, reason), do: {[], {:error, reason}}

  defp run(media, conversions, source) do
    media = derive_original(media, source)

    {derived, result} =
      if conversions == [],
        do: {derive(media, &generate_placeholders(&1, [], write: false)), :ok},
        else: convert(media, conversions, source)

    changes =
      derived
      |> Map.take([:custom_properties, :generated_conversions, :responsive_images])
      |> Enum.to_list()

    {changes, result}
  end

  # The original's WebP, AVIF, variants and BlurHash the record doesn't have yet:
  # an upload made them already; an import (PhxMediaLibrary.import_media/2)
  # leaves them to this job. Each step skips what its settings turn off.
  defp derive_original(media, source) do
    steps = [source: source, write: false]
    props = media.custom_properties || %{}

    media
    |> derive_unless(is_binary(props["webp"]), &Pipeline.webp(&1, steps))
    |> derive_unless(is_binary(props["avif"]), &Pipeline.avif(&1, steps))
    |> derive_unless(ResponsiveImages.formats(media, nil) != [], &Pipeline.responsive(&1, steps))
    |> derive_unless(
      is_binary((media.responsive_images || %{})["blurhash"]),
      &Pipeline.blurhash(&1, steps)
    )
  end

  defp derive_unless(media, true, _step), do: media
  defp derive_unless(media, false, step), do: derive(media, step)

  defp finish(media, changes, result) do
    status =
      case result do
        :ok -> [processing_finished_at: now()]
        {:error, reason} -> [processing_failed_at: now(), processing_error: describe(reason)]
      end

    with :ok <- record(media, changes ++ status), do: result
  end

  defp describe(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 1_000)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Returns the media with what it made, and how the conversions went.
  defp convert(%Media{} = media, conversions, original_path) do
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)
    plans = Enum.map(conversions, &plan(media, &1, processor))

    case processor.open(original_path) do
      {:ok, image} ->
        results = Enum.map(plans, &process_conversion(media, image, &1, processor, storage))

        generated =
          for {{conversion, _formats, recorded}, {:ok, _name}} <- Enum.zip(plans, results),
              into: %{},
              do: {to_string(conversion.name), recorded}

        # The responsive variants and placeholders go into the same struct
        # (`write: false`), so the job writes the row once (spec 02, C4).
        derived =
          %{media | generated_conversions: Map.merge(media.generated_conversions, generated)}
          |> derive(&maybe_generate_responsive_for_conversions(&1, results, write: false))
          |> derive(&generate_placeholders(&1, results, write: false))

        {derived, conversion_failures(media, results)}

      {:error, _reason} = error ->
        {media, error}
    end
  end

  defp conversion_failures(media, results) do
    case Enum.reject(results, &match?({:ok, _}, &1)) do
      [] ->
        :ok

      failures ->
        Logger.warning(
          "[PhxMediaLibrary] conversions failed for media #{inspect(media.id)}: " <>
            inspect(failures)
        )

        {:error, {:conversions_failed, failures}}
    end
  end

  @doc """
  Process a single conversion.
  """
  @spec process_single(Media.t(), Conversion.t()) :: :ok | {:error, term()}
  def process_single(%Media{} = media, %Conversion{} = conversion) do
    LocalSource.with_image(media, &process_single(media, conversion, &1))
  end

  defp process_single(%Media{} = media, %Conversion{} = conversion, original_path) do
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)
    {conversion, _formats, recorded} = plan = plan(media, conversion, processor)

    with {:ok, image} <- processor.open(original_path),
         {:ok, _} <- process_conversion(media, image, plan, processor, storage) do
      updated = Map.put(media.generated_conversions, to_string(conversion.name), recorded)
      record(media, generated_conversions: updated)
    end
  end

  # A conversion with the formats it is made in (Model.formats/4, without
  # those the image processor can't write) and what generated_conversions
  # will record for it.
  defp plan(media, %Conversion{} = conversion, processor) do
    formats =
      media
      |> Model.formats(media.collection_name, media.mime_type, conversion)
      |> writable(processor)

    {conversion, formats, recorded(media, formats)}
  end

  # AVIF needs a libvips built with it; without, the other formats are
  # still made. A list of nothing writable is kept, so the conversion fails.
  defp writable(formats, processor) do
    case Enum.filter(formats, &writable?(&1, processor)) do
      ^formats ->
        formats

      [] ->
        formats

      writable ->
        if Keyword.has_key?(formats, :avif), do: PhxMediaLibrary.Avif.log_unsupported_once()
        writable
    end
  end

  defp writable?({:original, _opts}, _processor), do: true

  defp writable?({format, _opts}, processor),
    do: PhxMediaLibrary.ImageProcessor.supports_format?(processor, format)

  defp process_conversion(media, image, {conversion, formats, recorded}, processor, storage) do
    telemetry_metadata = %{media: media, conversion: conversion.name}

    Telemetry.span([:phx_media_library, :conversion], telemetry_metadata, fn ->
      paths =
        PathGenerator.conversion_paths(
          with_recorded(media, conversion, recorded),
          conversion.name
        )

      previous_paths = previous_paths(media, conversion)

      result =
        with {:ok, converted} <- processor.apply_conversion(image, conversion),
             :ok <-
               store_formats(converted, Enum.zip(formats, paths), conversion, processor, storage) do
          # Rebuilt in other formats: the old files are no longer owned.
          Enum.each(previous_paths -- paths, &StorageWrapper.delete(storage, &1))
          {:ok, conversion.name}
        else
          error -> {:error, {conversion.name, error}}
        end

      stop_metadata =
        case result do
          {:ok, name} -> %{conversion: name}
          {:error, reason} -> %{error: reason}
        end

      {result, stop_metadata}
    end)
  end

  # The resized image, saved in each format to its path. A format's own
  # quality wins over the conversion's.
  defp store_formats(image, formats_and_paths, conversion, processor, storage) do
    Enum.reduce_while(formats_and_paths, :ok, fn {{format, opts}, path}, :ok ->
      case store_format(
             image,
             format,
             opts[:quality] || conversion.quality,
             path,
             processor,
             storage
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp store_format(image, format, quality, path, processor, storage) do
    temp_path = temp_file_path(path)
    opts = Enum.reject([format: format, quality: quality], fn {_, v} -> is_nil(v) end)

    try do
      with {:ok, _} <- processor.save(image, temp_path, opts),
           {:ok, content} <- File.read(temp_path) do
        StorageWrapper.put(storage, path, content)
      end
    after
      File.rm(temp_path)
    end
  end

  # Where the conversion was stored before, if it was generated already.
  defp previous_paths(media, conversion) do
    if Map.has_key?(media.generated_conversions || %{}, to_string(conversion.name)),
      do: PathGenerator.conversion_paths(media, conversion.name),
      else: []
  end

  # What generated_conversions records for a conversion, which
  # PathGenerator turns into its files' extensions: for one format, its
  # extension, or `true` for the original's (as before 0.10); for several,
  # their extensions in priority order.
  defp recorded(_media, [{format, _opts}]), do: extension(format)

  defp recorded(media, formats) do
    original =
      media |> PathGenerator.relative_path(nil) |> Path.extname() |> String.trim_leading(".")

    Enum.map(formats, fn {format, _opts} ->
      if format == :original, do: original, else: extension(format)
    end)
  end

  defp extension(:original), do: true
  defp extension(format), do: Atom.to_string(format)

  defp with_recorded(%Media{} = media, %Conversion{} = conversion, recorded) do
    recorded = Map.put(media.generated_conversions || %{}, to_string(conversion.name), recorded)
    %{media | generated_conversions: recorded}
  end

  # The files exist only if the record says so: a failed write fails the
  # job, so it can be retried.
  defp record(%Media{} = media, changes) do
    case Media.save_changes(media, changes) do
      {:ok, _media} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[PhxMediaLibrary] could not record the conversions of media #{inspect(media.id)}: " <>
            inspect(reason)
        )

        {:error, {:record_update_failed, reason}}
    end
  end

  # Responsive variants of the new conversions (see
  # Model.conversion_responsive?/2 for when), with the collection's widths.
  defp maybe_generate_responsive_for_conversions(media, results, opts) do
    case successful_conversion_names(results) do
      [] -> :skipped
      names -> Pipeline.responsive(media, [of: names] ++ opts)
    end
  end

  # Placeholders for the original and the new conversions (crops).
  defp generate_placeholders(media, results, opts) do
    Pipeline.placeholder(media, [of: [nil | successful_conversion_names(results)]] ++ opts)
  end

  # A failed or skipped step leaves the media as it was.
  defp derive(media, step) do
    case step.(media) do
      {:ok, %Media{} = derived} -> derived
      _skipped_or_failed -> media
    end
  end

  defp successful_conversion_names(results) do
    results
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, name} -> name end)
  end

  defp temp_file_path(path) do
    dir = System.tmp_dir!()
    filename = Path.basename(path)
    Path.join(dir, "phx_media_conversion_#{:erlang.unique_integer([:positive])}_#{filename}")
  end
end
