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
    FileName,
    Media,
    MediaAdder,
    MimeDetector,
    Model,
    PathGenerator,
    StorageWrapper,
    Telemetry
  }

  import Ecto.Query, only: [from: 2, where: 3, exclude: 2]

  @doc """
  Start adding media to a model from a file path, an upload, or content in
  memory or in a stream.

  Sources:

  - a path, a `Plug.Upload`, or a map with `:path` and `:filename` (a
    LiveView upload entry)
  - `{:binary, data, filename}`: content in memory
  - `{:base64, data, filename}`: base64, or a `data:` URI
  - `{:stream, enumerable, filename}`: chunks of iodata, e.g. a
    `File.stream!/2` or an S3 download stream; it stops at the
    collection's `max_size`

  The filename gives the stored name and the claimed type; the content is
  checked like any upload (type from the bytes, size, pixels). Returns a
  `MediaAdder` struct that can be piped through configuration functions
  before finalizing with `to_collection/2`.

  ## Examples

      post
      |> PhxMediaLibrary.add("/path/to/file.jpg")
      |> PhxMediaLibrary.to_collection(:images)

      post
      |> PhxMediaLibrary.add({:binary, png_bytes, "chart.png"})
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec add(Ecto.Schema.t(), MediaAdder.source()) :: MediaAdder.t()
  def add(model, source) do
    MediaAdder.new(model, source)
  end

  @doc """
  Add media from a remote URL.

  The file is streamed to a temporary file before processing. Only `http`
  and `https` URLs are accepted, and hosts on private or loopback networks
  are refused (including after redirects). See `PhxMediaLibrary.Downloader`.

  ## Options

  - `:headers`: custom request headers (e.g. `[{"Authorization", "Bearer token"}]`)
  - `:timeout`: receive timeout between chunks, in milliseconds
  - `:total_timeout`: limit for the whole download (default 5 minutes)
  - `:max_size`: maximum size in bytes (defaults to the collection's `max_size`)
  - `:allow_private_hosts`: allow private/loopback hosts, e.g. an intranet

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

  This is useful for composing queries with Ecto. You can add further
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
    mediable_type = Model.mediable_type(model)
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

  Uses media preloaded through the model's `has_media` associations when
  present, so pages listing many records don't run one query per record:

      products = Product |> Repo.all() |> Repo.preload(:images)
      # no further queries:
      Enum.map(products, &PhxMediaLibrary.get_first_media_url(&1, :images, :thumb))

  Otherwise it queries. Preloaded media is as fresh as when it was loaded.

  ## Examples

      PhxMediaLibrary.get_media(post)
      PhxMediaLibrary.get_media(post, :images)

  """
  @spec get_media(Ecto.Schema.t(), atom() | nil) :: [Media.t()]
  def get_media(model, collection_name \\ nil) do
    case Model.preloaded_media(model, collection_name) do
      {:ok, media} -> media
      :not_loaded -> model |> media_query(collection_name) |> Config.repo().all()
    end
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
      PhxMediaLibrary.get_first_media_url(post, :images, width: 320)

  Options other than `:fallback` are forwarded to `PhxMediaLibrary.Media.url/3`
  (`:width`, `:cache_bust`, adapter options).
  """
  @spec get_first_media_url(Ecto.Schema.t(), atom(), atom() | keyword()) :: String.t() | nil
  def get_first_media_url(model, collection_name, conversion_or_opts \\ [])

  def get_first_media_url(model, collection_name, conversion) when is_atom(conversion) do
    get_first_media_url(model, collection_name, conversion, [])
  end

  def get_first_media_url(model, collection_name, opts) when is_list(opts) do
    get_first_media_url(model, collection_name, nil, opts)
  end

  @doc """
  Like `get_first_media_url/3`, with both a conversion and options.

  ## Examples

      PhxMediaLibrary.get_first_media_url(post, :images, :thumb, fallback: "/placeholder.jpg")

  """
  @spec get_first_media_url(Ecto.Schema.t(), atom(), atom() | nil, keyword()) :: String.t() | nil
  def get_first_media_url(model, collection_name, conversion, opts) do
    {fallback, url_opts} = Keyword.pop(opts, :fallback)

    case get_first_media(model, collection_name) do
      nil -> fallback
      media -> Media.url(media, conversion, url_opts)
    end
  end

  @doc """
  Get the URL for a media item, optionally for a specific conversion.

  Accepts the same options as `PhxMediaLibrary.UrlGenerator.url/3`, including
  `cache_bust: true`, `signed: true`, `download: true`, and `expires_in`.
  """
  @spec url(Media.t(), atom() | nil, keyword()) :: String.t()
  defdelegate url(media, conversion \\ nil, opts \\ []), to: Media

  @doc """
  A full URL (scheme and host included) for `og:image` tags, image sitemaps,
  emails and APIs. `base` is your endpoint or a URL string. See
  `PhxMediaLibrary.UrlGenerator.absolute_url/4`.

  ## Examples

      <meta property="og:image" content={PhxMediaLibrary.absolute_url(@product.image, :preview, MyAppWeb.Endpoint)} />

  """
  @spec absolute_url(Media.t(), atom() | nil, module() | String.t(), keyword()) :: String.t()
  defdelegate absolute_url(media, conversion, base, opts \\ []), to: PhxMediaLibrary.UrlGenerator

  @doc """
  Get a CDN-friendly URL with a cache-busting fingerprint query parameter.

  Appends `?vsn={checksum[0..7]}` when the media item has a stored checksum so
  CDN edges pick up the new file whenever it is replaced. Falls back to a
  plain URL when no checksum is stored.

  Equivalent to `PhxMediaLibrary.url(media, conversion, cache_bust: true)`.

  ## Examples

      PhxMediaLibrary.cdn_url(media)
      #=> "/uploads/images/1/uuid/photo.jpg?vsn=a1b2c3d4"

  """
  @spec cdn_url(Media.t(), atom() | nil) :: String.t()
  defdelegate cdn_url(media, conversion \\ nil), to: Media

  @doc """
  Get a download URL that triggers `Content-Disposition: attachment`.

  For **S3** storage this generates a presigned GET URL with the
  `response-content-disposition` query parameter included in the AWS
  Signature V4 canonical request.

  For **local disk** storage the URL routes through
  `PhxMediaLibrary.Plug.MediaDownload`, which serves the file with the
  proper header. The plug must be mounted in the app's router.

  ## Options

  - `:filename`: override the filename in the header (default: `media.file_name`).
  - `:expires_in`: presigned URL expiry in seconds for S3 (default: `3600`).

  ## Examples

      # In a template
      <a href={PhxMediaLibrary.download_url(@media)} download>Download</a>

  """
  @spec download_url(Media.t(), atom() | nil, keyword()) :: String.t()
  defdelegate download_url(media, conversion \\ nil, opts \\ []), to: Media

  @doc """
  Get a signed, time-limited URL for a media item.

  For **S3** this is an AWS Signature V4 presigned GET URL. For **local disk**
  this is an HMAC-SHA256–signed URL verified by
  `PhxMediaLibrary.Plug.MediaDownload`. A `secret_key_base` must be present in
  the disk config and the plug must be mounted.

  ## Options

  - `:expires_in`: seconds until the URL expires (default: `3600`).
  - `:download`: also add a `Content-Disposition: attachment` header.

  ## Examples

      PhxMediaLibrary.signed_url(media)
      PhxMediaLibrary.signed_url(media, nil, expires_in: 300)
      PhxMediaLibrary.signed_url(media, nil, download: true, expires_in: 600)

  """
  @spec signed_url(Media.t(), atom() | nil, keyword()) :: String.t()
  defdelegate signed_url(media, conversion \\ nil, opts \\ []), to: Media

  @doc """
  Get the BlurHash string for a media item, or `nil` if not generated.

  Blurhash must be opted in via `config :phx_media_library, responsive_images:
  [blurhash: true]` and the `:image` library must be available.

  Use the `<PhxMediaLibrary.Components.blurhash>` component to render the
  decoded placeholder client-side via a `<canvas>` element.

  ## Examples

      PhxMediaLibrary.blurhash(media)
      #=> "LKO2?V%2Tw=w]~RBVZRi};RPxuwH"

  """
  @spec blurhash(Media.t()) :: String.t() | nil
  defdelegate blurhash(media), to: Media

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

  This is the inverse of `get_media/2`. It returns only trashed items.

  ## Examples

      PhxMediaLibrary.get_trashed_media(post)
      PhxMediaLibrary.get_trashed_media(post, :images)

  """
  @spec get_trashed_media(Ecto.Schema.t(), atom() | nil) :: [Media.t()]
  def get_trashed_media(model, collection_name \\ nil) do
    mediable_type = Model.mediable_type(model)
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
    mediable_type = Model.mediable_type(model)
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
        Enum.each(trashed_items, &Media.delete_files/1)

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
  Merge `properties` into a media item's custom properties and save; `nil`
  removes a key. See `PhxMediaLibrary.Media.update_custom_properties/2`.

  ## Examples

      {:ok, media} = PhxMediaLibrary.update_custom_properties(media, %{caption: "New in"})

  """
  @spec update_custom_properties(Media.t(), map()) ::
          {:ok, Media.t()} | {:error, Ecto.Changeset.t() | {:reserved_properties, [String.t()]}}
  defdelegate update_custom_properties(media, properties), to: Media

  @doc """
  Set a media item's alt text; `nil` removes it. See
  `PhxMediaLibrary.Media.update_alt_text/2`.

  ## Examples

      {:ok, media} = PhxMediaLibrary.update_alt_text(media, "Red summer dress, front view")

  """
  @spec update_alt_text(Media.t(), String.t() | nil) ::
          {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_alt_text(media, alt), to: Media

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
          Enum.each(media_items, &Media.delete_files/1)

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
          Enum.each(media_items, &Media.delete_files/1)

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
  Import many media at once: a list or stream of
  `%{model:, collection:, source:}` entries, across any records and
  collections. Each file is checked and stored like an upload; rows are
  written in batches, and every derivative is made in the background, one
  job per row. See `PhxMediaLibrary.Import` for the options.

  ## Examples

      {:ok, %{inserted: inserted, failed: failed}} =
        PhxMediaLibrary.import_media(
          Enum.map(products, &%{model: &1, collection: :images, source: {:url, &1.image_url}}),
          max_concurrency: 8
        )

  """
  @spec import_media(Enumerable.t(), keyword()) ::
          {:ok, %{inserted: non_neg_integer(), failed: [{map(), term()}]}}
  defdelegate import_media(entries, opts \\ []), to: PhxMediaLibrary.Import, as: :run

  @doc """
  Copy a media item to another record or collection, as a new record with
  its own files.

  The original is added again as an upload would be: the target
  collection's checks, file naming, formats and conversions apply, and its
  derivatives are made again. Your `custom_properties` (alt text, captions)
  carry over. Deleting either media item leaves the other whole. See
  `PhxMediaLibrary.Transfer`.

  ## Options

  - `:disk`: store the copy on this disk (default: the target collection's)

  ## Examples

      {:ok, copy} = PhxMediaLibrary.copy_media(media, other_post, :images)

  """
  @spec copy_media(Media.t(), Ecto.Schema.t(), atom(), keyword()) ::
          {:ok, Media.t()} | {:error, term()}
  defdelegate copy_media(media, model, collection_name, opts \\ []),
    to: PhxMediaLibrary.Transfer,
    as: :copy

  @doc """
  Move a media item to another record or collection. The record keeps its
  `id`; its original is added again under the target collection's rules
  (checks, file naming, formats, conversions, limits), and its old files are
  deleted. Its `uuid` and URLs change. A move the target's rules refuse
  returns the error and changes nothing. See `PhxMediaLibrary.Transfer`.

  ## Options

  - `:disk`: move it to this disk (default: the target collection's)

  ## Examples

      {:ok, moved} = PhxMediaLibrary.move_media(media, other_post, :gallery)
      {:error, {:image_too_narrow, 120, 200}} = PhxMediaLibrary.move_media(media, user, :avatar)

  """
  @spec move_media(Media.t(), Ecto.Schema.t(), atom(), keyword()) ::
          {:ok, Media.t()} | {:error, term()}
  defdelegate move_media(media, model, collection_name, opts \\ []),
    to: PhxMediaLibrary.Transfer,
    as: :move

  @doc """
  Set a media item's position within its collection.

  Shifts other items' `order_column` values to make room, then sets the
  target item's position. Position is 1-based.

  ## Examples

      PhxMediaLibrary.set_position(media, 1)   # first
      PhxMediaLibrary.set_position(media, 3)   # third

  """
  @spec set_position(Media.t(), pos_integer()) :: {:ok, Media.t()} | {:error, term()}
  def set_position(%Media{} = media, position) when is_integer(position) and position >= 1 do
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

    # Reuse reorder logic. We need the model info from the media record.
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
  Sign a direct upload from the browser to remote storage (e.g. S3).

  The file goes straight to storage without passing through your server.
  The server signs the upload here and, after the browser has sent the
  file, creates the `Media` record with `complete_external_upload/4`.

  Returns `{:ok, upload}`, a map with:
  - `:method`: `:post` or `:put`, from the disk's `direct_upload:` setting
  - `:url`: where the browser sends the file
  - `:fields`: for `:post`, the form fields to send before the file (S3
    checks them against a signed policy: the exact key, the size limit and
    the content type); empty for `:put`
  - `:headers`: for `:put`, the headers to send (the signed
    `content-type`); empty for `:post`
  - `:key`: the storage path to pass to `complete_external_upload/4`

  See the "Direct uploads to S3" section of the storage guide for a
  LiveView uploader that handles both methods.

  Returns `{:error, {:file_too_large, size, max}}` when the declared
  `:size` is over the limit, and `{:error, :not_supported}` if the storage
  adapter can't sign uploads (e.g. local disk storage).

  ## Options

  - `:filename`: the name the user uploaded (required)
  - `:disk`: storage disk to use (default: collection or global default)
  - `:content_type`: the upload's MIME type (default: from the filename)
  - `:size`: the size the browser declares, checked against the limit
    before signing
  - `:expires_in`: URL expiration in seconds (default: 3600)
  - `:max_size`: maximum upload size in bytes (default: the collection's
    `max_size`); a POST enforces it at upload, a PUT at completion

  ## Examples

      {:ok, upload} =
        PhxMediaLibrary.presigned_upload(post, :images,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          size: 123_456
        )

      # The browser uploads with upload.method, upload.url, upload.fields
      # and upload.headers. Then the server completes:
      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, upload.key,
          filename: "photo.jpg"
        )

  """
  @spec presigned_upload(Ecto.Schema.t(), atom(), keyword()) ::
          {:ok,
           %{
             method: :post | :put,
             url: String.t(),
             fields: map(),
             headers: map(),
             key: String.t()
           }}
          | {:error, term()}
  def presigned_upload(model, collection_name, opts \\ []) do
    filename = opts |> Keyword.fetch!(:filename) |> FileName.safe()
    max_size = max_upload_size(model, collection_name, opts)

    with :ok <- check_declared_size(Keyword.get(opts, :size), max_size) do
      disk = Keyword.get(opts, :disk) || Model.default_disk(model, collection_name)
      storage = Config.storage_adapter(disk)
      content_type = Keyword.get(opts, :content_type) || MIME.from_path(filename)

      uuid = PhxMediaLibrary.UUIDv7.generate()
      mediable_type = Model.mediable_type(model)

      file_name =
        FileName.storage_name(Model.file_naming(model, collection_name), %{
          original: filename,
          mime_type: content_type,
          mediable_type: mediable_type,
          mediable_id: model.id,
          collection_name: collection_name,
          uuid: uuid
        })

      storage_path =
        PathGenerator.for_new_media(%{
          mediable_type: mediable_type,
          mediable_id: model.id,
          uuid: uuid,
          file_name: file_name
        })

      presigned_opts =
        opts
        |> Keyword.take([:expires_in])
        |> Keyword.put(:content_type, content_type)
        |> maybe_add_size_constraint(max_size)

      case StorageWrapper.presigned_upload(storage, storage_path, presigned_opts) do
        {:ok, upload} -> {:ok, Map.put(upload, :key, storage_path)}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Complete a direct (presigned) upload by creating the `Media` record.

  Call this after the client has finished uploading directly to storage.
  The object's size and first bytes are read from storage, never taken from
  the client, and checked against the collection like any upload (accepted
  types, `max_size`, content matching the extension). An object that fails
  is deleted and the call returns `{:error, reason}`; a missing object
  returns `{:error, :not_found}`.

  ## Required options

  - `:filename`: the name the user uploaded (kept for display)

  ## Optional options

  - `:disk`: storage disk (must match the one used for `presigned_upload/3`)
  - `:custom_properties`: user-defined metadata map
  - `:checksum`: pre-computed checksum (e.g. from client-side hashing)
  - `:checksum_algorithm`: algorithm used (default: `"sha256"`)
  - `:content_type`, `:size`: accepted for compatibility and ignored; both
    are read from the stored object

  ## Examples

      {:ok, media} =
        PhxMediaLibrary.complete_external_upload(post, :images, upload_key,
          filename: "photo.jpg"
        )

  """
  @spec complete_external_upload(Ecto.Schema.t(), atom(), String.t(), keyword()) ::
          {:ok, Media.t()} | {:error, term()}
  def complete_external_upload(model, collection_name, storage_path, opts) do
    filename = opts |> Keyword.fetch!(:filename) |> FileName.safe()
    disk = Keyword.get(opts, :disk) || Model.default_disk(model, collection_name)
    storage = Config.storage_adapter(disk)

    Telemetry.span(
      [:phx_media_library, :add],
      %{collection: collection_name, source_type: :external, model: model},
      fn ->
        result =
          with {:ok, file_info, header} <- stored_file(storage, storage_path, filename),
               :ok <-
                 validate_or_delete(
                   model,
                   collection_name,
                   file_info,
                   header,
                   storage,
                   storage_path
                 ),
               attrs = external_attrs(model, collection_name, storage_path, disk, file_info, opts),
               {:ok, media} <- insert_media(attrs) do
            Model.enforce_collection_limits(model, collection_name, media)
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

  # Same header size MediaAdder reads for MIME detection.
  @header_bytes 512

  defp stored_file(storage, storage_path, filename) do
    case StorageWrapper.stat(storage, storage_path, @header_bytes) do
      {:ok, %{size: size, header: header}} ->
        mime_type = MimeDetector.detect_with_fallback(header, filename)
        {:ok, %{filename: filename, mime_type: mime_type, size: size}, header}

      {:error, reason} when reason in [:not_found, :enoent] ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp validate_or_delete(model, collection_name, file_info, header, storage, storage_path) do
    with {:error, _} = error <-
           MediaAdder.validate_file(model, collection_name, file_info, header) do
      StorageWrapper.delete(storage, storage_path)
      error
    end
  end

  defp external_attrs(model, collection_name, storage_path, disk, file_info, opts) do
    checksum = Keyword.get(opts, :checksum)

    %{
      uuid: uuid_from_path(storage_path),
      collection_name: to_string(collection_name),
      name: FileName.slug(file_info.filename),
      # The name presigned_upload/3 stored the file under.
      file_name: Path.basename(storage_path),
      mime_type: file_info.mime_type,
      disk: to_string(disk),
      size: file_info.size,
      custom_properties: Keyword.get(opts, :custom_properties, %{}),
      metadata: %{"original_file_name" => file_info.filename},
      mediable_type: Model.mediable_type(model),
      mediable_id: model.id,
      order_column: Model.next_order(model, collection_name),
      checksum: checksum,
      checksum_algorithm: if(checksum, do: Keyword.get(opts, :checksum_algorithm, "sha256"))
    }
  end

  # Every path generator puts the media's UUID in the folder that holds the
  # file (Default, Flat, DateBased, Tenant).
  defp uuid_from_path(storage_path) do
    case storage_path |> Path.dirname() |> Path.basename() |> Ecto.UUID.cast() do
      {:ok, uuid} -> uuid
      :error -> PhxMediaLibrary.UUIDv7.generate()
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_reorder_transaction(model, collection_name, ordered_ids) do
    mediable_type = Model.mediable_type(model)
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

  defp check_declared_size(size, max) when is_integer(size) and is_integer(max) and size > max,
    do: {:error, {:file_too_large, size, max}}

  defp check_declared_size(_size, _max), do: :ok

  defp maybe_add_size_constraint(presigned_opts, nil), do: presigned_opts

  defp maybe_add_size_constraint(presigned_opts, max),
    do: Keyword.put(presigned_opts, :content_length_range, {0, max})

  # An explicit :max_size, else the collection's.
  defp max_upload_size(model, collection_name, opts) do
    case Keyword.fetch(opts, :max_size) do
      {:ok, max} ->
        max

      :error ->
        case Model.collection(model, collection_name) do
          %{max_size: max} -> max
          nil -> nil
        end
    end
  end

  defp insert_media(attrs) do
    %Media{}
    |> Media.changeset(attrs)
    |> Config.repo().insert()
  end

  defp maybe_process_conversions(model, media, collection_name) do
    conversions = Model.conversions(model, collection_name)

    if conversions != [] do
      Config.async_processor().process_async(media, conversions)
    end
  end
end
