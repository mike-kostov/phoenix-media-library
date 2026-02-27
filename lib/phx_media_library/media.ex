defmodule PhxMediaLibrary.Media do
  @moduledoc """
  The Media schema represents a file associated with an Ecto model.

  ## Fields

  - `uuid` - Unique identifier used in file paths
  - `collection_name` - The collection this media belongs to
  - `name` - Sanitized filename without extension
  - `file_name` - Original filename
  - `mime_type` - MIME type of the file
  - `disk` - Storage disk name (e.g., "local", "s3")
  - `size` - File size in bytes
  - `custom_properties` - User-defined metadata
  - `generated_conversions` - Map of conversion names to completion status
  - `responsive_images` - Data for responsive image srcset
  - `mediable_type` - The type of the associated model (e.g., "posts")
  - `mediable_id` - The ID of the associated model
  - `order_column` - For ordering media within a collection
  - `checksum` - SHA-256 (or other algorithm) hash of the file contents
  - `checksum_algorithm` - Algorithm used for the checksum (e.g., "sha256")

  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias PhxMediaLibrary.{Config, PathGenerator, ResponsiveImages, StorageWrapper, UrlGenerator}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
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

    # Polymorphic association
    field(:mediable_type, :string)
    field(:mediable_id, :binary_id)

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(uuid collection_name name file_name mime_type disk size mediable_type mediable_id)a
  @optional_fields ~w(custom_properties generated_conversions responsive_images order_column checksum checksum_algorithm)a

  @doc false
  def changeset(media, attrs) do
    media
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:uuid)
  end

  @doc """
  Query media for a given model, optionally filtered by collection.
  """
  @spec for_model(Ecto.Schema.t(), atom() | nil) :: [t()]
  def for_model(model, collection_name \\ nil) do
    {mediable_type, mediable_id} = get_mediable_info(model)

    query =
      from(m in __MODULE__,
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

    Config.repo().all(query)
  end

  @doc """
  Get the URL for this media item.
  """
  @spec url(t(), atom() | nil) :: String.t()
  def url(%__MODULE__{} = media, conversion \\ nil) do
    UrlGenerator.url(media, conversion)
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
  Get the srcset attribute value for responsive images.
  """
  @spec srcset(t(), atom() | nil) :: String.t() | nil
  def srcset(%__MODULE__{responsive_images: responsive} = media, conversion \\ nil) do
    key = conversion_key(conversion)

    case Map.get(responsive, key) do
      nil ->
        nil

      %{"variants" => variants} when is_list(variants) ->
        build_srcset(media, variants, conversion)

      # Legacy format: list of variants directly
      variants when is_list(variants) ->
        build_srcset(media, variants, conversion)

      _ ->
        nil
    end
  end

  @doc """
  Delete a media item and all its files.
  """
  @spec delete(t()) :: :ok | {:error, term()}
  def delete(%__MODULE__{} = media) do
    # Delete all files (original + conversions)
    :ok = delete_files(media)

    # Delete database record
    case Config.repo().delete(media) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
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
  Check if a conversion has been generated.
  """
  @spec has_conversion?(t(), atom()) :: boolean()
  def has_conversion?(%__MODULE__{generated_conversions: conversions}, name) do
    Map.get(conversions, to_string(name), false)
  end

  # Private functions

  defp get_mediable_info(model) do
    type =
      if function_exported?(model.__struct__, :__media_type__, 0) do
        model.__struct__.__media_type__()
      else
        # Fallback for schemas that don't `use PhxMediaLibrary.HasMedia`:
        # derive from Ecto table name if available, otherwise fall back to
        # underscored module name (without naive pluralization).
        if function_exported?(model.__struct__, :__schema__, 1) do
          model.__struct__.__schema__(:source)
        else
          model.__struct__
          |> Module.split()
          |> List.last()
          |> Macro.underscore()
        end
      end

    {type, model.id}
  end

  defp conversion_key(nil), do: "original"
  defp conversion_key(conversion), do: to_string(conversion)

  defp build_srcset(media, sizes, _conversion) do
    Enum.map_join(sizes, ", ", fn %{"width" => width, "path" => path} ->
      url = UrlGenerator.url_for_path(media, path)
      "#{url} #{width}w"
    end)
  end

  defp delete_files(%__MODULE__{disk: disk} = media) do
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

    # Delete responsive images
    media.responsive_images
    |> Map.values()
    |> List.flatten()
    |> Enum.each(fn %{"path" => path} ->
      StorageWrapper.delete(storage, path)
    end)

    :ok
  end
end
