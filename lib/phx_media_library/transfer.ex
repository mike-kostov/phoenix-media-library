defmodule PhxMediaLibrary.Transfer do
  @moduledoc """
  Copies and moves media to another record or collection
  (`PhxMediaLibrary.copy_media/4`, `PhxMediaLibrary.move_media/4`).

  Both add the original again, through the same path as an upload: the
  target collection's checks (accepted types, size, pixels, dimensions),
  file naming, disk, formats and conversions apply, and its derivatives are
  made as for a new upload, conversions in the background. A media item
  that breaks the target's rules is refused, and nothing changes.

  A copy is a new record with its own files. A move keeps the record's
  `id`, gets a new `uuid` and new files, and deletes its old files once the
  record is updated; its URLs change.

      {:ok, copy} = PhxMediaLibrary.Transfer.copy(media, other_post, :images)
      {:ok, moved} = PhxMediaLibrary.Transfer.move(media, other_post, :gallery)
  """

  alias PhxMediaLibrary.{Config, LocalSource, Media, MediaAdder, PathGenerator, StorageWrapper}

  # What the library itself keeps in custom_properties: the WebP and AVIF
  # steps record their files there. The new record makes its own.
  @derived_properties ~w(webp webp_width webp_height avif)

  @doc """
  Copy a media item to `model`'s `collection_name`, as a new record with
  its own files. `opts` are `to_collection/3`'s (`:disk`).

  ## Examples

      {:ok, copy} = PhxMediaLibrary.Transfer.copy(media, other_post, :images)

  """
  @spec copy(Media.t(), Ecto.Schema.t(), atom(), keyword()) :: {:ok, Media.t()} | {:error, term()}
  def copy(%Media{} = media, model, collection_name, opts \\ []) do
    add_again(media, model, collection_name, opts)
  end

  @doc """
  Move a media item to `model`'s `collection_name`. The record keeps its
  `id`; its files are made again under the target's rules, and the old
  ones are deleted. `opts` are `to_collection/3`'s (`:disk`).

  ## Examples

      {:ok, moved} = PhxMediaLibrary.Transfer.move(media, other_post, :gallery)

  """
  @spec move(Media.t(), Ecto.Schema.t(), atom(), keyword()) :: {:ok, Media.t()} | {:error, term()}
  def move(%Media{} = media, model, collection_name, opts \\ []) do
    with {:ok, moved} <- add_again(media, model, collection_name, [replacing: media] ++ opts) do
      storage = Config.storage_adapter(media.disk)

      Enum.each(
        Media.owned_paths(media) -- Media.owned_paths(moved),
        &StorageWrapper.delete(storage, &1)
      )

      {:ok, moved}
    end
  end

  defp add_again(media, model, collection_name, opts) do
    with_source(media, fn path, filename ->
      model
      |> MediaAdder.new(%{path: path, filename: filename})
      |> MediaAdder.with_custom_properties(
        Map.drop(media.custom_properties || %{}, @derived_properties)
      )
      |> MediaAdder.to_collection(collection_name, opts)
    end)
  end

  # The original, or its WebP when the collection dropped the original
  # (webp: [keep_original: false]), named so its extension matches.
  defp with_source(media, fun) do
    storage = Config.storage_adapter(media.disk)
    original = PathGenerator.relative_path(media, nil)
    name = Media.original_file_name(media)

    case (media.custom_properties || %{})["webp"] do
      webp when is_binary(webp) ->
        if StorageWrapper.exists?(storage, original),
          do: LocalSource.with_stored_path(media, original, &fun.(&1, name)),
          else:
            LocalSource.with_stored_path(media, webp, &fun.(&1, Path.rootname(name) <> ".webp"))

      _ ->
        LocalSource.with_stored_path(media, original, &fun.(&1, name))
    end
  end
end
