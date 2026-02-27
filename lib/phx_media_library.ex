defmodule PhxMediaLibrary do
  @moduledoc """
  A robust, Ecto-backed media management library for Elixir and Phoenix.

  PhxMediaLibrary provides a simple, fluent API for:
  - Associating files with Ecto schemas
  - Organizing media into collections
  - Storing files across different storage backends (local, S3)
  - Generating image conversions (thumbnails, etc.)
  - Creating responsive images for optimal loading

  ## Quick Start

  1. Add `use PhxMediaLibrary.HasMedia` to your Ecto schema
  2. Run `mix phx_media_library.install` to generate the migration
  3. Start associating media with your models!

  ## Example

      # In your schema
      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          has_media()
          timestamps()
        end

        def media_collections do
          [
            collection(:images),
            collection(:documents, accepts: ~w(application/pdf)),
            collection(:avatar, single_file: true)
          ]
        end

        def media_conversions do
          [
            conversion(:thumb, width: 150, height: 150, fit: :cover),
            conversion(:preview, width: 800)
          ]
        end
      end

      # Adding media
      post
      |> PhxMediaLibrary.add("/path/to/image.jpg")
      |> PhxMediaLibrary.to_collection(:images)

      # Retrieving media
      PhxMediaLibrary.get_first_media_url(post, :images)
      PhxMediaLibrary.get_first_media_url(post, :images, :thumb)

  """

  alias PhxMediaLibrary.{
    Config,
    Error,
    Media,
    MediaAdder,
    PathGenerator,
    StorageWrapper,
    Telemetry
  }

  import Ecto.Query, only: [from: 2, where: 3, exclude: 2]

  @doc """
  Start adding media to a model from a file path or upload.

  Returns a `MediaAdder` struct that can be piped through configuration
  functions before finalizing with `to_collection/2`.

  ## Examples

      post
      |> PhxMediaLibrary.add("/path/to/file.jpg")
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec add(Ecto.Schema.t(), Path.t() | map()) :: MediaAdder.t()
  def add(model, source) do
    MediaAdder.new(model, source)
  end

  @doc """
  Add media from a remote URL.

  The file will be downloaded and stored locally before processing.

  ## Examples

      post
      |> PhxMediaLibrary.add_from_url("https://example.com/image.jpg")
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec add_from_url(Ecto.Schema.t(), String.t()) :: MediaAdder.t()
  def add_from_url(model, url) do
    MediaAdder.new(model, {:url, url})
  end

  @doc """
  Set a custom filename for the media.
  """
  @spec using_filename(MediaAdder.t(), String.t()) :: MediaAdder.t()
  defdelegate using_filename(adder, filename), to: MediaAdder

  @doc """
  Attach custom properties (metadata) to the media.
  """
  @spec with_custom_properties(MediaAdder.t(), map()) :: MediaAdder.t()
  defdelegate with_custom_properties(adder, properties), to: MediaAdder

  @doc """
  Enable responsive image generation for this media.
  """
  @spec with_responsive_images(MediaAdder.t()) :: MediaAdder.t()
  defdelegate with_responsive_images(adder), to: MediaAdder

  @doc """
  Finalize adding media to a collection.

  ## Options

  - `:disk` - Override the storage disk for this media

  ## Examples

      post
      |> PhxMediaLibrary.add(upload)
      |> PhxMediaLibrary.to_collection(:images)

      post
      |> PhxMediaLibrary.add(upload)
      |> PhxMediaLibrary.to_collection(:images, disk: :s3)

  """
  @spec to_collection(MediaAdder.t(), atom(), keyword()) ::
          {:ok, Media.t()} | {:error, term()}
  defdelegate to_collection(adder, collection_name, opts \\ []), to: MediaAdder

  @doc """
  Same as `to_collection/3` but raises on error.

  Raises `PhxMediaLibrary.Error` if the operation fails.
  """
  @spec to_collection!(MediaAdder.t(), atom(), keyword()) :: Media.t()
  def to_collection!(adder, collection_name, opts \\ []) do
    case to_collection(adder, collection_name, opts) do
      {:ok, media} ->
        media

      {:error, %{message: message} = error} ->
        raise Error,
          message: "Failed to add media to collection #{inspect(collection_name)}: #{message}",
          reason: :add_failed,
          metadata: %{collection: collection_name, original_error: error}

      {:error, reason} ->
        raise Error,
          message:
            "Failed to add media to collection #{inspect(collection_name)}: #{inspect(reason)}",
          reason: :add_failed,
          metadata: %{collection: collection_name, original_error: reason}
    end
  end

  @doc """
  Returns an `Ecto.Query` for all media belonging to a model, optionally
  filtered by collection.

  This is useful for composing queries with Ecto — you can add further
  filters, selects, limits, or use it with `Repo.all/1`, `Repo.one/1`, etc.

  ## Examples

      # All media for a post
      PhxMediaLibrary.media_query(post)
      |> Repo.all()

      # Only images
      PhxMediaLibrary.media_query(post, :images)
      |> Repo.all()

      # Compose with further constraints
      PhxMediaLibrary.media_query(post, :images)
      |> where([m], m.mime_type == "image/png")
      |> Repo.all()

  """
  @spec media_query(Ecto.Schema.t(), atom() | nil) :: Ecto.Query.t()
  def media_query(model, collection_name \\ nil) do
    mediable_type = get_mediable_type(model)
    mediable_id = model.id

    query =
      from(m in Media,
        where: m.mediable_type == ^mediable_type,
        where: m.mediable_id == ^mediable_id,
        order_by: [asc: m.order_column, asc: m.inserted_at]
      )

    if collection_name do
      where(query, [m], m.collection_name == ^to_string(collection_name))
    else
      query
    end
  end

  @doc """
  Get all media for a model, optionally filtered by collection.

  ## Examples

      PhxMediaLibrary.get_media(post)
      PhxMediaLibrary.get_media(post, :images)

  """
  @spec get_media(Ecto.Schema.t(), atom() | nil) :: [Media.t()]
  def get_media(model, collection_name \\ nil) do
    model
    |> media_query(collection_name)
    |> Config.repo().all()
  end

  @doc """
  Get the first media item for a model in a collection.
  """
  @spec get_first_media(Ecto.Schema.t(), atom()) :: Media.t() | nil
  def get_first_media(model, collection_name) do
    model
    |> get_media(collection_name)
    |> List.first()
  end

  @doc """
  Get the URL for the first media item in a collection.

  ## Examples

      PhxMediaLibrary.get_first_media_url(post, :images)
      PhxMediaLibrary.get_first_media_url(post, :images, :thumb)
      PhxMediaLibrary.get_first_media_url(post, :avatar, fallback: "/default.jpg")

  """
  @spec get_first_media_url(Ecto.Schema.t(), atom(), atom() | keyword()) :: String.t() | nil
  def get_first_media_url(model, collection_name, conversion_or_opts \\ [])

  def get_first_media_url(model, collection_name, conversion) when is_atom(conversion) do
    get_first_media_url(model, collection_name, conversion, [])
  end

  def get_first_media_url(model, collection_name, opts) when is_list(opts) do
    get_first_media_url(model, collection_name, nil, opts)
  end

  @spec get_first_media_url(Ecto.Schema.t(), atom(), atom() | nil, keyword()) :: String.t() | nil
  def get_first_media_url(model, collection_name, conversion, opts) do
    fallback = Keyword.get(opts, :fallback)

    case get_first_media(model, collection_name) do
      nil -> fallback
      media -> Media.url(media, conversion)
    end
  end

  @doc """
  Get the URL for a media item, optionally for a specific conversion.
  """
  @spec url(Media.t(), atom() | nil) :: String.t()
  defdelegate url(media, conversion \\ nil), to: Media

  @doc """
  Get the filesystem path for a media item (local storage only).
  """
  @spec path(Media.t(), atom() | nil) :: String.t() | nil
  defdelegate path(media, conversion \\ nil), to: Media

  @doc """
  Get the srcset attribute value for responsive images.
  """
  @spec srcset(Media.t(), atom() | nil) :: String.t() | nil
  defdelegate srcset(media, conversion \\ nil), to: Media

  @doc """
  Delete a media item and its files from storage.
  """
  @spec delete(Media.t()) :: :ok | {:error, term()}
  defdelegate delete(media), to: Media

  @doc """
  Verify the integrity of a stored media file by comparing its stored
  checksum against a freshly computed one.

  Returns `:ok` if the checksums match, `{:error, :checksum_mismatch}` if
  they differ, or `{:error, :no_checksum}` if no checksum was stored.

  ## Examples

      case PhxMediaLibrary.verify_integrity(media) do
        :ok -> IO.puts("File is intact")
        {:error, :checksum_mismatch} -> IO.puts("File has been corrupted!")
        {:error, :no_checksum} -> IO.puts("No checksum stored for this media")
      end

  """
  @spec verify_integrity(Media.t()) :: :ok | {:error, :checksum_mismatch | :no_checksum | term()}
  defdelegate verify_integrity(media), to: Media

  @doc """
  Delete all media in a collection for a model.

  Deletes files from storage for each item, then removes all matching
  database records in a single query. This is significantly more efficient
  than deleting one-by-one for large collections.

  ## Examples

      PhxMediaLibrary.clear_collection(post, :images)

  """
  @spec clear_collection(Ecto.Schema.t(), atom()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def clear_collection(model, collection_name) do
    media_items = get_media(model, collection_name)

    Telemetry.span(
      [:phx_media_library, :batch],
      %{operation: :clear_collection, count: length(media_items)},
      fn ->
        # Delete files from storage for each item
        Enum.each(media_items, &delete_files/1)

        # Delete all matching records in a single query
        {count, _} =
          model
          |> media_query(collection_name)
          |> exclude(:order_by)
          |> Config.repo().delete_all()

        {{:ok, count}, %{operation: :clear_collection, count: count}}
      end
    )
  end

  @doc """
  Delete all media for a model.

  Deletes files from storage for each item, then removes all matching
  database records in a single query.

  ## Examples

      PhxMediaLibrary.clear_media(post)

  """
  @spec clear_media(Ecto.Schema.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def clear_media(model) do
    media_items = get_media(model)

    Telemetry.span(
      [:phx_media_library, :batch],
      %{operation: :clear_media, count: length(media_items)},
      fn ->
        # Delete files from storage for each item
        Enum.each(media_items, &delete_files/1)

        # Delete all matching records in a single query
        {count, _} =
          model
          |> media_query()
          |> exclude(:order_by)
          |> Config.repo().delete_all()

        {{:ok, count}, %{operation: :clear_media, count: count}}
      end
    )
  end

  @doc """
  Reorder media items in a collection by a list of IDs.

  Sets the `order_column` for each media record according to its position
  in the given ID list. Uses a single database transaction with individual
  updates for correctness.

  IDs not present in the collection are silently ignored. Media items in
  the collection whose IDs are not in the list keep their current order
  but are shifted after the explicitly ordered items.

  ## Examples

      # Set explicit order: id3 first, id1 second, id2 third
      PhxMediaLibrary.reorder(post, :images, [id3, id1, id2])

  """
  @spec reorder(Ecto.Schema.t(), atom(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reorder(model, collection_name, ordered_ids) when is_list(ordered_ids) do
    Telemetry.span(
      [:phx_media_library, :batch],
      %{operation: :reorder, count: length(ordered_ids)},
      fn ->
        result = do_reorder_transaction(model, collection_name, ordered_ids)

        case result do
          {:ok, count} ->
            Telemetry.event(
              [:phx_media_library, :reorder],
              %{count: count},
              %{model: model, collection: collection_name}
            )

            {{:ok, count}, %{operation: :reorder, count: count}}

          {:error, reason} ->
            {{:error, reason}, %{operation: :reorder, error: reason}}
        end
      end
    )
  end

  @doc """
  Move a single media item to a specific position within its collection.

  Shifts other items' `order_column` values to make room, then sets the
  target item's position. Position is 1-based.

  ## Examples

      PhxMediaLibrary.move_to(media, 1)   # move to first position
      PhxMediaLibrary.move_to(media, 3)   # move to third position

  """
  @spec move_to(Media.t(), pos_integer()) :: {:ok, Media.t()} | {:error, term()}
  def move_to(%Media{} = media, position) when is_integer(position) and position >= 1 do
    # Get all items in the same collection, ordered
    siblings =
      from(m in Media,
        where: m.mediable_type == ^media.mediable_type,
        where: m.mediable_id == ^media.mediable_id,
        where: m.collection_name == ^media.collection_name,
        order_by: [asc: m.order_column, asc: m.inserted_at]
      )
      |> Config.repo().all()

    # Remove the target from the list and reinsert at position
    others = Enum.reject(siblings, &(&1.id == media.id))
    clamped_position = min(position, length(others) + 1)
    reordered = List.insert_at(others, clamped_position - 1, media)

    ordered_ids = Enum.map(reordered, & &1.id)

    # Reuse reorder logic — we need the model info from the media record
    Config.repo().transaction(fn ->
      ordered_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {id, pos} ->
        from(m in Media, where: m.id == ^id)
        |> Config.repo().update_all(set: [order_column: pos])
      end)
    end)

    # Return the updated media
    case Config.repo().get(Media, media.id) do
      nil -> {:error, :not_found}
      updated -> {:ok, updated}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_reorder_transaction(model, collection_name, ordered_ids) do
    mediable_type = get_mediable_type(model)
    collection_str = to_string(collection_name)

    Config.repo().transaction(fn ->
      ordered_ids
      |> Enum.with_index(1)
      |> Enum.reduce(0, fn {id, position}, acc ->
        {count, _} =
          from(m in Media,
            where: m.id == ^id,
            where: m.mediable_type == ^mediable_type,
            where: m.mediable_id == ^model.id,
            where: m.collection_name == ^collection_str
          )
          |> Config.repo().update_all(set: [order_column: position])

        acc + count
      end)
    end)
  end

  defp get_mediable_type(model) do
    if function_exported?(model.__struct__, :__media_type__, 0) do
      model.__struct__.__media_type__()
    else
      if function_exported?(model.__struct__, :__schema__, 1) do
        model.__struct__.__schema__(:source)
      else
        model.__struct__
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
      end
    end
  end

  # Delete all files (original + conversions + responsive) from storage
  # for a media item, without touching the database record.
  defp delete_files(%Media{disk: disk} = media) do
    storage = Config.storage_adapter(disk)

    # Delete original
    original_path = PathGenerator.relative_path(media, nil)
    StorageWrapper.delete(storage, original_path)

    # Delete conversions
    media.generated_conversions
    |> Map.keys()
    |> Enum.each(fn conversion ->
      conversion_path = PathGenerator.relative_path(media, conversion)
      StorageWrapper.delete(storage, conversion_path)
    end)

    # Delete responsive image variants
    media.responsive_images
    |> Map.values()
    |> List.flatten()
    |> Enum.each(fn
      %{"path" => path} -> StorageWrapper.delete(storage, path)
      _ -> :ok
    end)

    :ok
  end
end
