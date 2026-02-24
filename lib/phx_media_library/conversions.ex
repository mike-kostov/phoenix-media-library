defmodule PhxMediaLibrary.Conversions do
  @moduledoc """
  Handles the execution of image conversions.
  """

  alias PhxMediaLibrary.{Media, Conversion, Config, PathGenerator}

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
    end
  end

  defp process_conversion(media, image, %Conversion{} = conversion, processor, storage) do
    with {:ok, converted} <- processor.apply_conversion(image, conversion),
         conversion_path <- PathGenerator.relative_path(media, conversion.name),
         temp_path <- temp_file_path(conversion_path),
         :ok <- processor.save(converted, temp_path, format: conversion.format, quality: conversion.quality),
         :ok <- storage.put(conversion_path, File.read!(temp_path)) do
      File.rm(temp_path)
      {:ok, conversion.name}
    else
      error ->
        {:error, {conversion.name, error}}
    end
  end

  defp update_generated_conversions(%Media{} = media, new_conversions) do
    updated = Map.merge(media.generated_conversions, new_conversions)

    media
    |> Ecto.Changeset.change(generated_conversions: updated)
    |> Config.repo().update()

    :ok
  end

  defp temp_file_path(path) do
    dir = System.tmp_dir!()
    filename = Path.basename(path)
    Path.join(dir, "phx_media_conversion_#{:erlang.unique_integer([:positive])}_#{filename}")
  end
end
