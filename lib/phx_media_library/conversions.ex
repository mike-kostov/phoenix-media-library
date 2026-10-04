defmodule PhxMediaLibrary.Conversions do
  @moduledoc """
  Handles the execution of image conversions.
  """

  alias PhxMediaLibrary.{
    Config,
    Conversion,
    LocalSource,
    Media,
    PathGenerator,
    Pipeline,
    StorageWrapper,
    Telemetry
  }

  require Logger

  @doc """
  Process all conversions for a media item.

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
    # deleted or updated (a real race — and common with async tasks in tests).
    # Working from the current row avoids Ecto.StaleEntryError on the conversion
    # and responsive updates below.
    case Config.repo().get(Media, media.id) do
      nil ->
        Logger.debug(
          "[PhxMediaLibrary] media #{inspect(media.id)} no longer exists — skipping conversions"
        )

        :ok

      fresh ->
        LocalSource.with_path(fresh, nil, &process(fresh, conversions, &1))
    end
  end

  defp process(%Media{} = media, conversions, original_path) do
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)

    with {:ok, image} <- processor.open(original_path) do
      results =
        Enum.map(conversions, fn conversion ->
          process_conversion(media, image, conversion, processor, storage)
        end)

      # Update media with generated conversions
      generated =
        results
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, name} -> {to_string(name), true} end)
        |> Map.new()

      update_generated_conversions(media, generated)

      # Generate responsive images for conversions if enabled
      maybe_generate_responsive_for_conversions(media, results)

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
  end

  @doc """
  Process a single conversion.
  """
  @spec process_single(Media.t(), Conversion.t()) :: :ok | {:error, term()}
  def process_single(%Media{} = media, %Conversion{} = conversion) do
    LocalSource.with_path(media, nil, &process_single(media, conversion, &1))
  end

  defp process_single(%Media{} = media, %Conversion{} = conversion, original_path) do
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)

    with {:ok, image} <- processor.open(original_path),
         {:ok, _} <- process_conversion(media, image, conversion, processor, storage) do
      update_generated_conversions(media, %{to_string(conversion.name) => true})
      :ok
    end
  end

  defp process_conversion(media, image, %Conversion{} = conversion, processor, storage) do
    telemetry_metadata = %{media: media, conversion: conversion.name}

    Telemetry.span([:phx_media_library, :conversion], telemetry_metadata, fn ->
      conversion_path = PathGenerator.relative_path(media, conversion.name)
      temp_path = temp_file_path(conversion_path)

      result =
        try do
          with {:ok, converted} <- processor.apply_conversion(image, conversion),
               {:ok, _} <- save_image(processor, converted, temp_path, conversion),
               {:ok, content} <- File.read(temp_path),
               :ok <- StorageWrapper.put(storage, conversion_path, content) do
            {:ok, conversion.name}
          else
            error ->
              {:error, {conversion.name, error}}
          end
        after
          File.rm(temp_path)
        end

      stop_metadata =
        case result do
          {:ok, name} -> %{conversion: name}
          {:error, reason} -> %{error: reason}
        end

      {result, stop_metadata}
    end)
  end

  defp save_image(processor, image, path, conversion) do
    opts =
      [
        format: conversion.format,
        quality: conversion.quality
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    processor.save(image, path, opts)
  end

  defp update_generated_conversions(%Media{} = media, new_conversions) do
    updated = Map.merge(media.generated_conversions, new_conversions)

    media
    |> Ecto.Changeset.change(generated_conversions: updated)
    |> Config.repo().update()

    :ok
  end

  # Responsive variants of the new conversions (see
  # Model.conversion_responsive?/2 for when), with the collection's widths.
  defp maybe_generate_responsive_for_conversions(media, results) do
    case successful_conversion_names(results) do
      [] -> :ok
      names -> Pipeline.responsive(Config.repo().reload!(media), of: names)
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
