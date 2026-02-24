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
    StorageWrapper
  }

  @doc """
  Process all conversions for a media item.
  """
  @spec process(Media.t(), [Conversion.t()]) :: :ok | {:error, term()}
  def process(%Media{} = media, conversions) do
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)

    # Get the original file
    original_path = PathGenerator.full_path(media, nil)

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
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)
    original_path = PathGenerator.full_path(media, nil)

    with {:ok, image} <- processor.open(original_path),
         {:ok, _} <- process_conversion(media, image, conversion, processor, storage) do
      update_generated_conversions(media, %{to_string(conversion.name) => true})
      :ok
    end
  end

  defp process_conversion(media, image, %Conversion{} = conversion, processor, storage) do
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
      # Get fresh media with updated conversions
      media = Config.repo().reload!(media)

      successful_conversions =
        results
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, name} -> name end)

      # Generate responsive images for each successful conversion
      responsive_data =
        Enum.reduce(successful_conversions, media.responsive_images, fn conversion_name, acc ->
          case ResponsiveImages.generate(media, conversion_name) do
            {:ok, data} -> Map.merge(acc, data)
            _ -> acc
          end
        end)

      # Update media with responsive image data
      media
      |> Ecto.Changeset.change(responsive_images: responsive_data)
      |> Config.repo().update()
    end
  end

  defp temp_file_path(path) do
    dir = System.tmp_dir!()
    filename = Path.basename(path)
    Path.join(dir, "phx_media_conversion_#{:erlang.unique_integer([:positive])}_#{filename}")
  end
end
