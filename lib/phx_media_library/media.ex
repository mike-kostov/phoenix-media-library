defmodule PhxMediaLibrary.Media do
  @moduledoc """
  The Media schema represents a file associated with an Ecto model.

      media = PhxMediaLibrary.get_first_media(post, :images)
      media.file_name                        #=> "posts_42_images_<uuid>.jpg"
      media.metadata["original_file_name"]   #=> "Summer dress.jpg"
      PhxMediaLibrary.url(media, :thumb)     #=> "/uploads/posts/42/<uuid>/posts_42_images_<uuid>_thumb.jpg"

  ## Fields

  - `uuid` - Unique identifier used in file paths
  - `collection_name` - The collection this media belongs to
  - `name` - The uploaded name as a slug, without extension
  - `file_name` - The stored filename, chosen by the library (see
    `PhxMediaLibrary.FileName`); the uploaded name is in
    `metadata["original_file_name"]`
  - `mime_type` - MIME type of the file
  - `disk` - Storage disk name (e.g., "local", "s3")
  - `size` - File size in bytes
  - `custom_properties` - User-defined metadata
  - `generated_conversions` - Map of generated conversion names to `true`,
    or to the file extension of a conversion stored in another format than
    the original (e.g. `"thumb" => "webp"`)
  - `responsive_images` - Data for responsive image srcset
  - `mediable_type` - The type of the associated model (e.g., "posts")
  - `mediable_id` - The ID of the associated model
  - `order_column` - For ordering media within a collection
  - `checksum` - SHA-256 (or other algorithm) hash of the file contents
  - `checksum_algorithm` - Algorithm used for the checksum (e.g., "sha256")
  - `metadata` - Automatically extracted file metadata (dimensions, duration, EXIF, etc.)

  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias PhxMediaLibrary.{
    Config,
    PathGenerator,
    ResponsiveImages,
    StorageWrapper,
    Telemetry,
    UrlGenerator
  }

  @type t :: %__MODULE__{}

  @mediable_id_type Application.compile_env(:phx_media_library, :mediable_id_type, :binary_id)

  # Time-ordered ids (UUIDv7): new rows land at the end of the index.
  @primary_key {:id, PhxMediaLibrary.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "media" do
    field(:uuid, :string)
    field(:collection_name, :string, default: "default")
    field(:name, :string)
    field(:file_name, :string)
    field(:mime_type, :string)
    field(:disk, :string)
    field(:size, :integer)
    field(:custom_properties, :map, default: %{})
    field(:generated_conversions, :map, default: %{})
    field(:responsive_images, :map, default: %{})
    field(:order_column, :integer)
    field(:checksum, :string)
    field(:checksum_algorithm, :string, default: "sha256")
    field(:metadata, :map, default: %{})
    field(:deleted_at, :utc_datetime)

    # Polymorphic association
    field(:mediable_type, :string)
    field(:mediable_id, @mediable_id_type)

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(uuid collection_name name file_name mime_type disk size mediable_type mediable_id)a
  @optional_fields ~w(custom_properties generated_conversions responsive_images order_column checksum checksum_algorithm metadata deleted_at)a

  @doc false
  def changeset(media, attrs) do
    media
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:uuid)
  end

  @doc """
  Query media for a given model, optionally filtered by collection.

  By default, soft-deleted records are excluded when soft deletes are
  enabled. Pass `include_trashed: true` to include them.
  """
  @spec for_model(Ecto.Schema.t(), atom() | nil) :: [t()]
  def for_model(model, collection_name \\ nil) do
    model
    |> for_model_query(collection_name)
    |> order_by([m], asc: m.order_column, asc: m.inserted_at)
    |> Config.repo().all()
  end

  defp for_model_query(model, collection_name) do
    mediable_type = PhxMediaLibrary.Model.mediable_type(model)
    mediable_id = model.id

    query =
      from(m in __MODULE__,
        where: m.mediable_type == ^mediable_type,
        where: m.mediable_id == ^mediable_id
      )

    query =
      if collection_name do
        where(query, [m], m.collection_name == ^to_string(collection_name))
      else
        query
      end

    exclude_trashed(query)
  end

  @doc """
  Get one media item by `id`, only if it belongs to `model` (and to
  `collection_name`, unless that is `nil`). Returns `nil` otherwise, or when
  `id` isn't a valid ID.

  Use this when the ID comes from a client (a LiveView event, a form), so a
  user can't reach media attached to another record by changing the ID.
  Whether the user may edit `model` at all is for your app to decide.

  ## Examples

      Media.get_for_model(post, :images, id)
      #=> %Media{} | nil

  """
  @spec get_for_model(Ecto.Schema.t(), atom() | String.t() | nil, term()) :: t() | nil
  def get_for_model(model, collection_name, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        model
        |> for_model_query(collection_name)
        |> where([m], m.id == ^id)
        |> Config.repo().one()

      :error ->
        nil
    end
  end

  @doc """
  Get the URL for this media item.

  Pass `opts` to forward adapter-specific options such as `signed: true`,
  `download: true`, or `cache_bust: true`. See `PhxMediaLibrary.UrlGenerator`
  for the full list.

  `width: 320` returns the URL of the smallest responsive variant at least that
  wide (the widest one when none is), so a thumbnail slot never downloads the
  full-size file. Media without responsive variants return their regular URL.

      Media.url(media, nil, width: 320)
      # => "/uploads/products/1/uuid/responsive/photo_320w.webp"
  """
  @spec url(t(), atom() | nil, keyword()) :: String.t()
  def url(%__MODULE__{} = media, conversion \\ nil, opts \\ []) do
    UrlGenerator.url(media, conversion, opts)
  end

  @doc """
  Get a CDN-friendly URL with a cache-busting fingerprint query parameter.

  Appends `?vsn={checksum[0..7]}` when the media item has a stored checksum,
  so CDN edges serve a fresh object whenever the file is replaced. Falls back
  to a plain URL when no checksum is available.

  Equivalent to `url(media, conversion, cache_bust: true)`.

  ## Examples

      iex> Media.cdn_url(media)
      "/uploads/images/1/uuid/photo.jpg?vsn=a1b2c3d4"

  """
  @spec cdn_url(t(), atom() | nil) :: String.t()
  def cdn_url(%__MODULE__{} = media, conversion \\ nil) do
    UrlGenerator.cdn_url(media, conversion)
  end

  @doc """
  Get a download URL that triggers a `Content-Disposition: attachment` header.

  For **S3** storage this generates a presigned GET URL with the
  `response-content-disposition` query parameter. For **local disk** storage
  the URL routes through `PhxMediaLibrary.Plug.MediaDownload`.

  Equivalent to `url(media, conversion, download: true)`.
  """
  @spec download_url(t(), atom() | nil, keyword()) :: String.t()
  def download_url(%__MODULE__{} = media, conversion \\ nil, opts \\ []) do
    UrlGenerator.download_url(media, conversion, opts)
  end

  @doc """
  Get a signed, time-limited URL for a media item.

  For **S3** this is an AWS Signature V4 presigned GET URL. For **local disk**
  storage this is an HMAC-signed URL verified by
  `PhxMediaLibrary.Plug.MediaDownload`.

  Equivalent to `url(media, conversion, signed: true)`.

  ## Options

  - `:expires_in`: seconds until the URL expires (default: `3600`).
  - `:download`: also force `Content-Disposition: attachment`.
  """
  @spec signed_url(t(), atom() | nil, keyword()) :: String.t()
  def signed_url(%__MODULE__{} = media, conversion \\ nil, opts \\ []) do
    UrlGenerator.signed_url(media, conversion, opts)
  end

  @doc """
  Get the filesystem path for this media item (local storage only).
  """
  @spec path(t(), atom() | nil) :: String.t() | nil
  def path(%__MODULE__{} = media, conversion \\ nil) do
    PathGenerator.full_path(media, conversion)
  end

  @doc """
  Get the tiny placeholder data URI for progressive loading.
  """
  @spec placeholder(t(), atom() | nil) :: String.t() | nil
  def placeholder(%__MODULE__{} = media, conversion \\ nil) do
    ResponsiveImages.placeholder(media, conversion)
  end

  @doc """
  Get the BlurHash string for a media item, or `nil` if not generated.

  Blurhash must be enabled in config and the `:image` library must be
  available. The hash is stored in `media.responsive_images["blurhash"]`
  after upload.

  Use the `<PhxMediaLibrary.Components.blurhash>` component to render the
  decoded placeholder client-side.

  ## Examples

      iex> Media.blurhash(media)
      "LKO2?V%2Tw=w]~RBVZRi};RPxuwH"

      iex> Media.blurhash(media_without_hash)
      nil

  """
  @spec blurhash(t()) :: String.t() | nil
  def blurhash(%__MODULE__{responsive_images: responsive}) do
    get_in(responsive || %{}, ["blurhash"])
  end

  # custom_properties keys the library maintains itself.
  @reserved_properties ~w(webp webp_width webp_height source_url)

  @doc """
  Merge `properties` into the media's custom properties and save. A `nil`
  value removes that key. Keys may be atoms or strings.

  The keys the library maintains itself (#{Enum.map_join(@reserved_properties, ", ", &"`#{&1}`")})
  are refused with `{:error, {:reserved_properties, keys}}`.

  ## Examples

      {:ok, media} = Media.update_custom_properties(media, %{alt: "Red summer dress", caption: "New in"})
      {:ok, media} = Media.update_custom_properties(media, %{caption: nil})

  """
  @spec update_custom_properties(t(), map()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t() | {:reserved_properties, [String.t()]}}
  def update_custom_properties(%__MODULE__{} = media, properties) when is_map(properties) do
    properties = Map.new(properties, fn {key, value} -> {to_string(key), value} end)

    case Enum.filter(Map.keys(properties), &(&1 in @reserved_properties)) do
      [] ->
        {removed, set} = Enum.split_with(properties, fn {_key, value} -> is_nil(value) end)

        updated =
          (media.custom_properties || %{})
          |> Map.drop(Enum.map(removed, &elem(&1, 0)))
          |> Map.merge(Map.new(set))

        media |> change(custom_properties: updated) |> Config.repo().update()

      reserved ->
        {:error, {:reserved_properties, reserved}}
    end
  end

  @doc """
  Set the alt text image components use for this media (see `alt_text/1`).
  `nil` removes it, falling back to the uploaded name.

  ## Examples

      {:ok, media} = Media.update_alt_text(media, "Red summer dress, front view")

  """
  @spec update_alt_text(t(), String.t() | nil) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_alt_text(%__MODULE__{} = media, alt),
    do: update_custom_properties(media, %{"alt" => alt})

  @doc """
  Width and height in pixels of the file served for the original
  (`conversion` nil) or a conversion, or `nil` when unknown.

  For the original this is the served WebP's size when it was capped
  (`webp: [max_dimension: ...]`), otherwise the extracted metadata. For a
  conversion it comes from its responsive variants, when generated.

  Image components use it for the `width`/`height` attributes, so the
  browser reserves the right space before the image loads.

  ## Examples

      Media.dimensions(media)
      #=> {1200, 800}

  """
  @spec dimensions(t(), atom() | String.t() | nil) :: {pos_integer(), pos_integer()} | nil
  def dimensions(media, conversion \\ nil)

  def dimensions(%__MODULE__{custom_properties: %{"webp_width" => w, "webp_height" => h}}, nil)
      when is_integer(w) and is_integer(h),
      do: {w, h}

  def dimensions(%__MODULE__{metadata: %{"width" => w, "height" => h}}, nil)
      when is_integer(w) and is_integer(h),
      do: {w, h}

  def dimensions(%__MODULE__{}, nil), do: nil

  def dimensions(%__MODULE__{responsive_images: responsive}, conversion) do
    variants = get_in(responsive || %{}, [to_string(conversion), "variants"]) || []

    case Enum.max_by(variants, &(&1["width"] || 0), fn -> nil end) do
      %{"width" => w, "height" => h} when is_integer(w) and is_integer(h) -> {w, h}
      _ -> nil
    end
  end

  @doc """
  Alt text for an image: `custom_properties["alt"]` when set, otherwise the
  uploaded file's name made readable ("red-summer_dress.jpg" →
  "red summer dress"). Never a library-chosen stored name such as
  `posts_42_images_<uuid>.jpg`; media uploaded before file naming has no
  `original_file_name`, but its `file_name` is the uploaded name.

  ## Examples

      Media.alt_text(%Media{custom_properties: %{"alt" => "Red summer dress"}})
      #=> "Red summer dress"

      Media.alt_text(%Media{metadata: %{"original_file_name" => "red-summer_dress.jpg"}})
      #=> "red summer dress"

  """
  @spec alt_text(t()) :: String.t()
  def alt_text(%__MODULE__{} = media) do
    case media.custom_properties do
      %{"alt" => alt} when is_binary(alt) ->
        alt

      _ ->
        ((media.metadata || %{})["original_file_name"] || media.file_name || "")
        |> Path.rootname()
        |> String.replace(~r/[-_.]+/, " ")
        |> String.trim()
    end
  end

  @doc """
  Every storage path this media record owns: the original, named conversions,
  the served WebP and AVIF siblings, responsive variants and the video poster. Used by
  `delete_files/1` and `mix phx_media_library.clean`.
  """
  @spec owned_paths(t()) :: [String.t()]
  def owned_paths(%__MODULE__{} = media) do
    original = PathGenerator.relative_path(media, nil)

    conversions =
      (media.generated_conversions || %{})
      |> Map.keys()
      |> Enum.flat_map(&PathGenerator.conversion_paths(media, &1))

    # The served WebP and the AVIF beside the original.
    siblings =
      for key <- ["webp", "avif"],
          path = (media.custom_properties || %{})[key],
          is_binary(path),
          do: path

    responsive =
      (media.responsive_images || %{})
      |> Map.values()
      |> Enum.flat_map(&paths_in/1)

    Enum.uniq([original | conversions ++ siblings ++ responsive])
  end

  @doc """
  Delete every file this media record owns (see `owned_paths/1`) from
  storage, without touching the database record. Missing files are ignored.

  ## Examples

      :ok = PhxMediaLibrary.Media.delete_files(media)

  """
  @spec delete_files(t()) :: :ok
  def delete_files(%__MODULE__{disk: disk} = media) do
    storage = Config.storage_adapter(disk)
    media |> owned_paths() |> Enum.each(&StorageWrapper.delete(storage, &1))
  end

  defp paths_in(%{"variants" => variants} = entry) when is_list(variants),
    do: Enum.flat_map(variants, &paths_in/1) ++ paths_in(Map.delete(entry, "variants"))

  defp paths_in(%{"path" => path}) when is_binary(path), do: [path]
  defp paths_in(list) when is_list(list), do: Enum.flat_map(list, &paths_in/1)
  defp paths_in(_), do: []

  @doc """
  Get the srcset attribute value for responsive images.

  A conversion with the original's shape lists the original's variants
  narrower than itself, then itself (ADR-024).
  """
  @spec srcset(t(), atom() | nil) :: String.t() | nil
  def srcset(%__MODULE__{} = media, conversion \\ nil) do
    case responsive_variants(media, conversion) do
      [] -> nil
      variants -> build_srcset(media, variants, conversion)
    end
  end

  @doc """
  The responsive variants of the original or a conversion, narrowest
  first, each a map with `"width"`, `"height"` and `"path"`. The last one
  is the full-size file. A conversion with the original's shape gets the
  original's variants narrower than itself, then itself.

  ## Examples

      Media.responsive_variants(media, :preview)
      #=> [%{"width" => 160, ...}, %{"width" => 320, ...}, %{"width" => 800, ...}]

  """
  @spec responsive_variants(t(), atom() | String.t() | nil) :: [map()]
  def responsive_variants(%__MODULE__{responsive_images: responsive}, conversion) do
    responsive = responsive || %{}
    entry = Map.get(responsive, conversion_key(conversion))
    own = entry |> variants_in() |> Enum.filter(&is_map/1)

    case entry do
      %{"reuses" => "original"} ->
        width = own |> Enum.map(& &1["width"]) |> Enum.max(fn -> 0 end)

        original =
          responsive
          |> Map.get("original")
          |> variants_in()
          |> Enum.filter(&(is_map(&1) and &1["width"] < width))

        Enum.sort_by(original ++ own, & &1["width"])

      _ ->
        Enum.sort_by(own, & &1["width"])
    end
  end

  # Responsive data is either %{"variants" => [...]} or a legacy bare list.
  defp variants_in(%{"variants" => variants}) when is_list(variants), do: variants
  defp variants_in(variants) when is_list(variants), do: variants
  defp variants_in(_), do: []

  @doc """
  Check whether a media item has been soft-deleted.
  """
  @spec trashed?(t()) :: boolean()
  def trashed?(%__MODULE__{deleted_at: nil}), do: false
  def trashed?(%__MODULE__{deleted_at: %DateTime{}}), do: true

  @doc """
  Soft-delete a media item by setting `deleted_at`.

  When soft deletes are enabled globally (`config :phx_media_library,
  soft_deletes: true`), this is called automatically by `delete/1`
  instead of permanently removing the record. Files are **not** removed
  from storage until `permanently_delete/1` is called.

  Returns `{:ok, media}` with the updated record, or `{:error, changeset}`.
  """
  @spec soft_delete(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def soft_delete(%__MODULE__{} = media) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    media
    |> Ecto.Changeset.change(deleted_at: now)
    |> Config.repo().update()
  end

  @doc """
  Restore a soft-deleted media item by clearing `deleted_at`.

  Returns `{:ok, media}` with the restored record, or `{:error, changeset}`.
  """
  @spec restore(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def restore(%__MODULE__{} = media) do
    media
    |> Ecto.Changeset.change(deleted_at: nil)
    |> Config.repo().update()
  end

  @doc """
  Permanently delete a media item and all its files from storage.

  This always performs a hard delete regardless of the soft deletes
  configuration. Use this for:
  - Permanently removing soft-deleted items
  - Force-deleting when soft deletes are enabled

  See also `delete/1` which respects the soft deletes configuration.
  """
  @spec permanently_delete(t()) :: :ok | {:error, term()}
  def permanently_delete(%__MODULE__{} = media) do
    Telemetry.span([:phx_media_library, :delete], %{media: media, permanent: true}, fn ->
      # Delete all files (original + conversions)
      :ok = delete_files(media)

      # Delete database record
      result =
        case Config.repo().delete(media) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {result, %{media: media, permanent: true}}
    end)
  end

  @doc """
  Delete a media item.

  When soft deletes are enabled (`config :phx_media_library, soft_deletes: true`),
  this sets the `deleted_at` timestamp instead of removing the record and files.
  Use `permanently_delete/1` to force a hard delete.

  When soft deletes are disabled (the default), this permanently removes
  the record and all associated files from storage.
  """
  @spec delete(t()) :: :ok | {:ok, t()} | {:error, term()}
  def delete(%__MODULE__{} = media) do
    if soft_deletes_enabled?() do
      soft_delete(media)
    else
      permanently_delete(media)
    end
  end

  @doc """
  Verify the integrity of a stored media file by comparing its checksum
  against the stored value.

  Returns `:ok` if the checksums match, `{:error, :checksum_mismatch}` if
  they don't, or `{:error, :no_checksum}` if no checksum was stored.
  """
  @spec verify_integrity(t()) :: :ok | {:error, :checksum_mismatch | :no_checksum | term()}
  def verify_integrity(%__MODULE__{checksum: nil}), do: {:error, :no_checksum}
  def verify_integrity(%__MODULE__{checksum_algorithm: nil}), do: {:error, :no_checksum}

  def verify_integrity(%__MODULE__{} = media) do
    storage = Config.storage_adapter(media.disk)
    relative = PathGenerator.relative_path(media, nil)

    with {:ok, content} <- StorageWrapper.get(storage, relative) do
      computed = compute_checksum(content, media.checksum_algorithm)

      if computed == media.checksum do
        :ok
      else
        {:error, :checksum_mismatch}
      end
    end
  end

  @doc """
  Compute a checksum for binary content using the given algorithm.

  Supported algorithms: `"sha256"` (default), `"md5"`, `"sha1"`.
  """
  @spec compute_checksum(binary(), String.t()) :: String.t()
  def compute_checksum(content, algorithm \\ "sha256") do
    hash_algorithm =
      case algorithm do
        "sha256" -> :sha256
        "sha1" -> :sha
        "md5" -> :md5
        other -> raise "Unsupported checksum algorithm: #{inspect(other)}"
      end

    :crypto.hash(hash_algorithm, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Write `changes` to the media's row, or, with `write: false`, only apply
  them to the struct. Processing steps use it so an upload can collect
  every step's changes and write its row once (spec 02, C4); repairs write
  per step.

  ## Examples

      {:ok, media} = Media.save_changes(media, custom_properties: %{"alt" => "A dress"})
      {:ok, unsaved} = Media.save_changes(media, [responsive_images: data], write: false)

  """
  @spec save_changes(t(), keyword() | map(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def save_changes(%__MODULE__{} = media, changes, opts \\ []) do
    changeset = Ecto.Changeset.change(media, changes)

    if Keyword.get(opts, :write, true),
      do: Config.repo().update(changeset),
      else: {:ok, Ecto.Changeset.apply_changes(changeset)}
  end

  @doc """
  Check if a conversion has been generated.
  """
  @spec has_conversion?(t(), atom()) :: boolean()
  def has_conversion?(%__MODULE__{generated_conversions: conversions}, name) do
    Map.get(conversions || %{}, to_string(name), false) not in [false, nil]
  end

  @doc """
  Returns whether soft deletes are enabled globally.
  """
  @spec soft_deletes_enabled?() :: boolean()
  def soft_deletes_enabled? do
    Application.get_env(:phx_media_library, :soft_deletes, false)
  end

  @doc """
  Adds a `WHERE deleted_at IS NULL` clause to the query when soft deletes
  are enabled. Returns the query unchanged otherwise.
  """
  @spec exclude_trashed(Ecto.Query.t()) :: Ecto.Query.t()
  def exclude_trashed(query) do
    if soft_deletes_enabled?() do
      where(query, [m], is_nil(m.deleted_at))
    else
      query
    end
  end

  @doc """
  Adds a `WHERE deleted_at IS NOT NULL` clause to only return trashed items.
  """
  @spec only_trashed(Ecto.Query.t()) :: Ecto.Query.t()
  def only_trashed(query) do
    where(query, [m], not is_nil(m.deleted_at))
  end

  # Private functions

  defp conversion_key(nil), do: "original"
  defp conversion_key(conversion), do: to_string(conversion)

  defp build_srcset(media, sizes, _conversion) do
    Enum.map_join(sizes, ", ", fn %{"width" => width, "path" => path} ->
      url = UrlGenerator.url_for_path(media, path)
      "#{url} #{width}w"
    end)
  end
end
