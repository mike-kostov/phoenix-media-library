defmodule PhxMediaLibrary.Conversions do
  @moduledoc """
  Handles the execution of image conversions.
  """

  alias PhxMediaLibrary.{
    Config,
    Conversion,
    Media,
    PathGenerator,
    ResponsiveImages,
    StorageWrapper,
    Telemetry
  }

  require Logger

  # Conversions need a local source file to read. Disks without a filesystem
  # path (memory, S3 without a downloaded copy) return nil from `full_path` —
  # skip with a warning instead of crashing on `Image.open(nil)`.
  defp no_local_source(%Media{} = media) do
    # Documented limitation (not an error): conversions read a local source, so
    # disks without a filesystem path (`:memory`, S3 without a local copy) can't
    # produce them. Debug-level so it never spams a correctly-configured app.
    Logger.debug(
      "[PhxMediaLibrary] conversions need a local source file; disk " <>
        "#{inspect(media.disk)} has none for media #{inspect(media.id)} — skipping"
    )

    :ok
  end

  @doc """
  Process all conversions for a media item.
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
        process(fresh, conversions, PathGenerator.full_path(fresh, nil))
    end
  end

  defp process(%Media{} = media, _conversions, nil), do: no_local_source(media)

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

      :ok
    end
  end

  @doc """
  Process a single conversion.
  """
  @spec process_single(Media.t(), Conversion.t()) :: :ok | {:error, term()}
  def process_single(%Media{} = media, %Conversion{} = conversion) do
    process_single(media, conversion, PathGenerator.full_path(media, nil))
  end

  defp process_single(%Media{} = media, %Conversion{}, nil), do: no_local_source(media)

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
      result =
        with {:ok, converted} <- processor.apply_conversion(image, conversion),
             conversion_path <- PathGenerator.relative_path(media, conversion.name),
             temp_path <- temp_file_path(conversion_path),
             {:ok, _} <- save_image(processor, converted, temp_path, conversion),
             {:ok, content} <- File.read(temp_path),
             :ok <- StorageWrapper.put(storage, conversion_path, content) do
          File.rm(temp_path)
          {:ok, conversion.name}
        else
          error ->
            {:error, {conversion.name, error}}
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

  defp maybe_generate_responsive_for_conversions(media, results) do
    if Config.responsive_images_enabled?() do
      generate_responsive_for_conversions(media, results)
    end
  end

  defp generate_responsive_for_conversions(media, results) do
    # Get fresh media with updated conversions
    media = Config.repo().reload!(media)
    conversion_names = successful_conversion_names(results)

    responsive_data =
      Enum.reduce(conversion_names, media.responsive_images, fn conversion_name, acc ->
        case ResponsiveImages.generate(media, conversion_name) do
          {:ok, data} -> Map.merge(acc, data)
          _ -> acc
        end
      end)

    media
    |> Ecto.Changeset.change(responsive_images: responsive_data)
    |> Config.repo().update()
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
