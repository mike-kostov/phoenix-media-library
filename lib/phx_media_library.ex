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
  URL validation ensures only `http` and `https` schemes are accepted.

  ## Options

  - `:headers` — custom request headers (e.g. `[{"Authorization", "Bearer token"}]`)
  - `:timeout` — download timeout in milliseconds

  ## Telemetry

  Downloads emit `[:phx_media_library, :download, :start | :stop | :exception]`
  events with URL, size, and MIME type metadata.

  ## Examples

      post
      |> PhxMediaLibrary.add_from_url("https://example.com/image.jpg")
      |> PhxMediaLibrary.to_collection(:images)

      # With authentication
      post
      |> PhxMediaLibrary.add_from_url("https://api.example.com/file.pdf",
           headers: [{"Authorization", "Bearer my-token"}])
      |> PhxMediaLibrary.to_collection(:documents)

  """
  @spec add_from_url(Ecto.Schema.t(), String.t(), keyword()) :: MediaAdder.t()
  def add_from_url(model, url, opts \\ []) do
    case opts do
      [] -> MediaAdder.new(model, {:url, url})
      _ -> MediaAdder.new(model, {:url, url, opts})
    end
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
  Disable automatic metadata extraction for this media.

  By default, PhxMediaLibrary extracts metadata (dimensions, EXIF, etc.)
  from uploaded files. Use this to skip extraction for a specific upload.

  ## Examples

      post
      |> PhxMediaLibrary.add(upload)
      |> PhxMediaLibrary.without_metadata()
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec without_metadata(MediaAdder.t()) :: MediaAdder.t()
  defdelegate without_metadata(adder), to: MediaAdder

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

    query =
      if collection_name do
        where(query, [m], m.collection_name == ^to_string(collection_name))
      else
        query
      end

    Media.exclude_trashed(query)
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
  @spec delete(Media.t()) :: :ok | {:ok, Media.t()} | {:error, term()}
  defdelegate delete(media), to: Media

  @doc """
  Permanently delete a media item and its files from storage.

  This always performs a hard delete regardless of whether soft deletes
  are enabled. Use this for force-deleting or cleaning up trashed items.
  """
  @spec permanently_delete(Media.t()) :: :ok | {:error, term()}
  defdelegate permanently_delete(media), to: Media

  @doc """
  Soft-delete a media item by setting its `deleted_at` timestamp.

  The record remains in the database but is excluded from all queries
  by default. Files are **not** removed from storage. Call
  `permanently_delete/1` to remove files and the database record.

  ## Examples

      {:ok, trashed} = PhxMediaLibrary.soft_delete(media)
      trashed.deleted_at  #=> ~U[2026-02-27 17:00:00Z]

  """
  @spec soft_delete(Media.t()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  defdelegate soft_delete(media), to: Media

  @doc """
  Restore a soft-deleted media item by clearing its `deleted_at` timestamp.

  ## Examples

      {:ok, restored} = PhxMediaLibrary.restore(media)
      restored.deleted_at  #=> nil

  """
  @spec restore(Media.t()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  defdelegate restore(media), to: Media

  @doc """
  Check whether a media item has been soft-deleted.

  ## Examples

      PhxMediaLibrary.trashed?(media)  #=> false
      {:ok, trashed} = PhxMediaLibrary.soft_delete(media)
      PhxMediaLibrary.trashed?(trashed)  #=> true

  """
  @spec trashed?(Media.t()) :: boolean()
  defdelegate trashed?(media), to: Media

  @doc """
  Get all soft-deleted media for a model, optionally filtered by collection.

  This is the inverse of `get_media/2` — it returns only trashed items.

  ## Examples

      PhxMediaLibrary.get_trashed_media(post)
      PhxMediaLibrary.get_trashed_media(post, :images)

  """
  @spec get_trashed_media(Ecto.Schema.t(), atom() | nil) :: [Media.t()]
  def get_trashed_media(model, collection_name \\ nil) do
    mediable_type = get_mediable_type(model)
    mediable_id = model.id

    query =
      from(m in Media,
        where: m.mediable_type == ^mediable_type,
        where: m.mediable_id == ^mediable_id,
        order_by: [asc: m.order_column, asc: m.inserted_at]
      )

    query =
      if collection_name do
        where(query, [m], m.collection_name == ^to_string(collection_name))
      else
        query
      end

    query
    |> Media.only_trashed()
    |> Config.repo().all()
  end

  @doc """
  Permanently delete all trashed media for a model that was soft-deleted
  before the given `DateTime`. Removes files from storage and database
  records.

  When called without a cutoff, permanently deletes **all** trashed media
  for the model.

  ## Examples

      # Delete everything trashed more than 30 days ago
      cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
      {:ok, count} = PhxMediaLibrary.purge_trashed(post, before: cutoff)

      # Delete all trashed media for the model
      {:ok, count} = PhxMediaLibrary.purge_trashed(post)

  """
  @spec purge_trashed(Ecto.Schema.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def purge_trashed(model, opts \\ []) do
    cutoff = Keyword.get(opts, :before)
    mediable_type = get_mediable_type(model)
    mediable_id = model.id

    query =
      from(m in Media,
        where: m.mediable_type == ^mediable_type,
        where: m.mediable_id == ^mediable_id,
        where: not is_nil(m.deleted_at)
      )

    query =
      if cutoff do
        where(query, [m], m.deleted_at < ^cutoff)
      else
        query
      end

    trashed_items = Config.repo().all(query)

    Telemetry.span(
      [:phx_media_library, :batch],
      %{operation: :purge_trashed, count: length(trashed_items)},
      fn ->
        Enum.each(trashed_items, &delete_files/1)

        {count, _} =
          query
          |> exclude(:order_by)
          |> Config.repo().delete_all()

        {{:ok, count}, %{operation: :purge_trashed, count: count}}
      end
    )
  end

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

    if Media.soft_deletes_enabled?() do
      # Soft-delete: set deleted_at on all items
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Telemetry.span(
        [:phx_media_library, :batch],
        %{operation: :clear_collection, count: length(media_items), soft: true},
        fn ->
          {count, _} =
            model
            |> media_query(collection_name)
            |> exclude(:order_by)
            |> Config.repo().update_all(set: [deleted_at: now])

          {{:ok, count}, %{operation: :clear_collection, count: count, soft: true}}
        end
      )
    else
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

    if Media.soft_deletes_enabled?() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Telemetry.span(
        [:phx_media_library, :batch],
        %{operation: :clear_media, count: length(media_items), soft: true},
        fn ->
          {count, _} =
            model
            |> media_query()
            |> exclude(:order_by)
            |> Config.repo().update_all(set: [deleted_at: now])

          {{:ok, count}, %{operation: :clear_media, count: count, soft: true}}
        end
      )
    else
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
  # Direct / Presigned Uploads
  # ---------------------------------------------------------------------------

  @doc """
  Generate a presigned URL for direct client-to-storage uploads.

  This allows the client (browser) to upload files directly to a remote
  storage backend (e.g. S3) without proxying through the server. The server
  only generates the signed URL and, after the upload completes, creates the
  `Media` record via `complete_external_upload/4`.

  Returns `{:ok, url, fields, upload_key}` on success, where:
  - `url` — the presigned upload endpoint
  - `fields` — a map of form fields for POST-based uploads (empty for PUT)
  - `upload_key` — the storage path to pass back to `complete_external_upload/4`

  Returns `{:error, :not_supported}` if the storage adapter doesn't support
  presigned URLs (e.g. local disk storage).

  ## Options

  - `:disk` — storage disk to use (default: collection or global default)
  - `:filename` — the filename for the upload (required)
  - `:content_type` — expected MIME type of the upload
  - `:expires_in` — URL expiration in seconds (default: 3600)
  - `:max_size` — maximum upload size in bytes

  ## Examples

      {:ok, url, fields, key} =
        PhxMediaLibrary.presigned_upload_url(post, :images,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          expires_in: 600
        )

      # Client uploads directly to `url` with `fields`
      # Then server completes:
      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, key,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          size: 123_456
        )

  """
  @spec presigned_upload_url(Ecto.Schema.t(), atom(), keyword()) ::
          {:ok, String.t(), map(), String.t()} | {:error, term()}
  def presigned_upload_url(model, collection_name, opts \\ []) do
    filename = Keyword.fetch!(opts, :filename)
    disk = Keyword.get(opts, :disk) || get_default_disk(model, collection_name)
    storage = Config.storage_adapter(disk)

    uuid = Ecto.UUID.generate()
    mediable_type = get_mediable_type(model)

    storage_path =
      PathGenerator.for_new_media(%{
        mediable_type: mediable_type,
        mediable_id: model.id,
        uuid: uuid,
        file_name: filename
      })

    presigned_opts =
      opts
      |> Keyword.take([:expires_in, :content_type])
      |> maybe_add_size_constraint(opts)

    case StorageWrapper.presigned_upload_url(storage, storage_path, presigned_opts) do
      {:ok, url, fields} ->
        {:ok, url, fields, storage_path}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Complete a direct (presigned) upload by creating the `Media` record.

  Call this after the client has finished uploading directly to storage.
  The file is already stored — this function only creates the database
  record and optionally triggers conversions.

  ## Required options

  - `:filename` — original filename
  - `:content_type` — MIME type of the uploaded file
  - `:size` — file size in bytes

  ## Optional options

  - `:disk` — storage disk (must match the one used for `presigned_upload_url/3`)
  - `:custom_properties` — user-defined metadata map
  - `:checksum` — pre-computed checksum (e.g. from client-side hashing)
  - `:checksum_algorithm` — algorithm used (default: `"sha256"`)

  ## Examples

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, upload_key,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          size: 45_000
        )

  """
  @spec complete_external_upload(Ecto.Schema.t(), atom(), String.t(), keyword()) ::
          {:ok, Media.t()} | {:error, term()}
  def complete_external_upload(model, collection_name, storage_path, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.fetch!(opts, :content_type)
    size = Keyword.fetch!(opts, :size)
    disk = Keyword.get(opts, :disk) || get_default_disk(model, collection_name)
    custom_properties = Keyword.get(opts, :custom_properties, %{})
    checksum = Keyword.get(opts, :checksum)
    checksum_algorithm = Keyword.get(opts, :checksum_algorithm, "sha256")

    # Extract UUID from the storage path (3rd segment: type/id/uuid/filename)
    uuid =
      storage_path
      |> Path.split()
      |> Enum.at(2) || Ecto.UUID.generate()

    mediable_type = get_mediable_type(model)

    attrs = %{
      uuid: uuid,
      collection_name: to_string(collection_name),
      name: sanitize_name(filename),
      file_name: filename,
      mime_type: content_type,
      disk: to_string(disk),
      size: size,
      custom_properties: custom_properties,
      metadata: %{},
      mediable_type: mediable_type,
      mediable_id: model.id,
      order_column: get_next_order(model, collection_name),
      checksum: checksum,
      checksum_algorithm: if(checksum, do: checksum_algorithm, else: nil)
    }

    Telemetry.span(
      [:phx_media_library, :add],
      %{collection: collection_name, source_type: :external, model: model},
      fn ->
        result =
          with {:ok, media} <- insert_media(attrs) do
            maybe_cleanup_collection(model, collection_name, media)
            maybe_process_conversions(model, media, collection_name)
            {:ok, media}
          end

        stop_metadata =
          case result do
            {:ok, media} -> %{media: media}
            {:error, reason} -> %{error: reason}
          end

        {result, stop_metadata}
      end
    )
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

  defp maybe_add_size_constraint(presigned_opts, opts) do
    case Keyword.get(opts, :max_size) do
      nil -> presigned_opts
      max -> Keyword.put(presigned_opts, :content_length_range, {0, max})
    end
  end

  defp get_default_disk(model, collection_name) do
    case get_collection_config(model, collection_name) do
      %{disk: disk} when not is_nil(disk) -> disk
      _ -> Config.default_disk()
    end
  end

  defp get_collection_config(model, collection_name) do
    if function_exported?(model.__struct__, :get_media_collection, 1) do
      model.__struct__.get_media_collection(collection_name)
    else
      nil
    end
  end

  defp get_next_order(model, collection_name) do
    mediable_type = get_mediable_type(model)
    collection_str = to_string(collection_name)

    query =
      from(m in Media,
        where: m.mediable_type == ^mediable_type,
        where: m.mediable_id == ^model.id,
        where: m.collection_name == ^collection_str,
        select: max(m.order_column)
      )

    case Config.repo().one(query) do
      nil -> 1
      max -> max + 1
    end
  end

  defp sanitize_name(filename) do
    filename
    |> Path.rootname()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp insert_media(attrs) do
    %Media{}
    |> Media.changeset(attrs)
    |> Config.repo().insert()
  end

  defp maybe_cleanup_collection(model, collection_name, new_media) do
    case get_collection_config(model, collection_name) do
      %{single_file: true} ->
        # Delete older media in collection, keep only the new one
        media_items = get_media(model, collection_name)

        media_items
        |> Enum.reject(&(&1.id == new_media.id))
        |> Enum.each(&Media.permanently_delete/1)

      %{max_files: max} when is_integer(max) and max > 0 ->
        media_items = get_media(model, collection_name)

        if length(media_items) > max do
          media_items
          |> Enum.drop(-max)
          |> Enum.each(&Media.permanently_delete/1)
        end

      _ ->
        :ok
    end
  end

  defp maybe_process_conversions(model, media, collection_name) do
    conversions =
      if function_exported?(model.__struct__, :get_media_conversions, 1) do
        model.__struct__.get_media_conversions(collection_name)
      else
        []
      end

    if conversions != [] do
      Config.async_processor().process_async(media, conversions)
    end
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
