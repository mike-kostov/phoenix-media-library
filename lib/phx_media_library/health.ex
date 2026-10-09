defmodule PhxMediaLibrary.Health do
  @moduledoc """
  Health checks for stored media, and the repair for each problem.

  `check/2` inspects one media item and returns its issues; `repair/2` fixes
  one issue by running the matching `PhxMediaLibrary.Pipeline` step, the
  same code uploads use. `mix phx_media_library.doctor` is built on this
  module; you can also call it from your own code (a scheduled job, an admin
  page):

      for issue <- PhxMediaLibrary.Health.check(media), not PhxMediaLibrary.Health.error?(issue) do
        PhxMediaLibrary.Health.repair(media, issue)
      end

  ## Issues

  | Issue                          | Severity   | Repair                        |
  |--------------------------------|------------|-------------------------------|
  | `:no_files`                    | error      | delete the record (`--fix`)   |
  | `:checksum_mismatch`           | error      | none, restore from backup     |
  | `{:missing_conversions, names}`| repairable | `Pipeline.conversions/2`      |
  | `:missing_webp`                | repairable | `Pipeline.webp/2`             |
  | `:missing_avif`                | repairable | `Pipeline.avif/2`             |
  | `:missing_placeholder`         | repairable | `Pipeline.placeholder/2`      |
  | `:outdated_placeholder`        | repairable | `Pipeline.placeholder/2`      |
  | `:missing_responsive`          | repairable | `Pipeline.responsive/2`       |
  | `:missing_blurhash`            | repairable | `Pipeline.blurhash/2`         |
  | `:missing_metadata`            | repairable | `Pipeline.metadata/2`         |
  | `:needs_rename`                | repairable | `Pipeline.rename/2`           |
  | `:original_not_dropped`        | repairable | `Pipeline.drop_original/2`    |

  Missing derivatives are only reported when the original is present,
  since that's what they are rebuilt from.
  """

  import Ecto.Query

  alias PhxMediaLibrary.{
    Config,
    DocumentRenderer,
    Media,
    Model,
    ModelRegistry,
    PathGenerator,
    Pipeline,
    ResponsiveImages,
    StorageWrapper
  }

  @typedoc "A problem found by `check/2`."
  @type issue ::
          :no_files
          | :checksum_mismatch
          | {:missing_conversions, [String.t()]}
          | :missing_webp
          | :missing_avif
          | :missing_placeholder
          | :outdated_placeholder
          | :missing_responsive
          | :missing_blurhash
          | :missing_metadata
          | :needs_rename
          | :original_not_dropped

  @doc """
  The issues of one media item, most fundamental first.

  Checks file existence through the media's storage adapter (one request
  per file on S3).

  ## Options

    * `:deep`: also verify the checksum, which reads the whole file

  ## Examples

      PhxMediaLibrary.Health.check(media)
      #=> [{:missing_conversions, ["thumb"]}, :needs_rename]

  """
  @spec check(Media.t(), keyword()) :: [issue()]
  def check(%Media{} = media, opts \\ []) do
    storage = Config.storage_adapter(media.disk)
    present = media |> Media.owned_paths() |> Enum.filter(&StorageWrapper.exists?(storage, &1))

    if present == [] do
      [:no_files]
    else
      original? = PathGenerator.relative_path(media, nil) in present

      [
        checksum_issue(media, opts),
        conversions_issue(media, present, original?),
        webp_issue(media, present, original?),
        avif_issue(media, present, original?),
        placeholder_issue(media, original?),
        responsive_issue(media, present, original?),
        blurhash_issue(media, original?),
        metadata_issue(media),
        name_issue(media),
        drop_issue(media, original?)
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  @doc """
  Whether an issue is an error (data lost or corrupt) rather than something
  a repair can rebuild.

  ## Examples

      iex> PhxMediaLibrary.Health.error?(:no_files)
      true

      iex> PhxMediaLibrary.Health.error?(:missing_webp)
      false

  """
  @spec error?(issue()) :: boolean()
  def error?(issue), do: issue in [:no_files, :checksum_mismatch]

  @doc """
  Repair one issue. `:no_files` deletes the record; `:checksum_mismatch`
  can't be repaired.

  ## Examples

      {:ok, media} = PhxMediaLibrary.Health.repair(media, :missing_webp)

  """
  @spec repair(Media.t(), issue()) :: :ok | {:ok, Media.t()} | {:skip, atom()} | {:error, term()}
  def repair(%Media{} = media, {:missing_conversions, names}),
    do: Pipeline.conversions(media, only: names)

  def repair(media, :missing_webp), do: Pipeline.webp(media)
  def repair(media, :missing_avif), do: Pipeline.avif(media)
  def repair(media, :missing_placeholder), do: Pipeline.placeholder(media)
  def repair(media, :outdated_placeholder), do: Pipeline.placeholder(media)

  def repair(media, :missing_responsive),
    do: Pipeline.responsive(media, of: [nil | Map.keys(media.generated_conversions || %{})])

  def repair(media, :missing_blurhash), do: Pipeline.blurhash(media)
  def repair(media, :missing_metadata), do: Pipeline.metadata(media)
  def repair(media, :needs_rename), do: Pipeline.rename(media)
  def repair(media, :original_not_dropped), do: Pipeline.drop_original(media)
  def repair(media, :no_files), do: Media.permanently_delete(media)
  def repair(_media, :checksum_mismatch), do: {:error, :not_repairable}

  @doc """
  IDs of parent records that media points at but that no longer exist, per
  `mediable_type`. Types whose model can't be found are listed under
  `:unknown_types`.

  ## Examples

      PhxMediaLibrary.Health.orphaned_parents()
      #=> %{orphans: %{"posts" => [17, 23]}, unknown_types: ["legacy_things"]}

  """
  @spec orphaned_parents() :: %{orphans: %{String.t() => [term()]}, unknown_types: [String.t()]}
  def orphaned_parents do
    repo = Config.repo()
    types = repo.all(from(m in Media, distinct: true, select: m.mediable_type))

    Enum.reduce(types, %{orphans: %{}, unknown_types: []}, &add_orphans(repo, &1, &2))
  end

  defp add_orphans(repo, type, acc) do
    case parent_module(type) do
      nil ->
        Map.update!(acc, :unknown_types, &[type | &1])

      module ->
        case missing_parent_ids(repo, type, module) do
          [] -> acc
          ids -> put_in(acc, [:orphans, type], ids)
        end
    end
  end

  defp parent_module(type) do
    with {:ok, module} <- ModelRegistry.find_model_module(type),
         true <- function_exported?(module, :__schema__, 1) do
      module
    else
      _ -> nil
    end
  end

  defp missing_parent_ids(repo, type, module) do
    media_parent_ids =
      repo.all(
        from(m in Media, where: m.mediable_type == ^type, distinct: true, select: m.mediable_id)
      )

    [primary_key | _] = module.__schema__(:primary_key)

    existing =
      from(s in {module.__schema__(:source), module})
      |> select([s], field(s, ^primary_key))
      |> repo.all()
      |> MapSet.new()

    Enum.reject(media_parent_ids, &MapSet.member?(existing, &1))
  end

  # -- Individual checks -------------------------------------------------------

  defp checksum_issue(media, opts) do
    if Keyword.get(opts, :deep) == true and is_binary(media.checksum) and
         Media.verify_integrity(media) == {:error, :checksum_mismatch},
       do: :checksum_mismatch
  end

  defp conversions_issue(media, present, true = _original?) do
    if DocumentRenderer.image_source?(media.mime_type) do
      missing =
        media
        |> Model.conversions(media.collection_name)
        |> Enum.map(&to_string(&1.name))
        |> Enum.reject(
          &Enum.all?(PathGenerator.conversion_paths(media, &1), fn p -> p in present end)
        )

      if missing != [], do: {:missing_conversions, missing}
    end
  end

  defp conversions_issue(_media, _present, false), do: nil

  defp webp_issue(media, present, true = _original?) do
    settings = Model.webp_settings(media, media.collection_name)

    expected? =
      Keyword.get(settings, :enabled, false) and
        PhxMediaLibrary.Webp.convertible?(media.mime_type)

    webp = (media.custom_properties || %{})["webp"]
    if expected? and webp not in present, do: :missing_webp
  end

  defp webp_issue(_media, _present, false), do: nil

  defp avif_issue(media, present, true = _original?) do
    settings = Model.avif_settings(media, media.collection_name)

    expected? =
      Keyword.get(settings, :enabled, false) and
        PhxMediaLibrary.Avif.convertible?(media.mime_type) and PhxMediaLibrary.Avif.supported?()

    avif = (media.custom_properties || %{})["avif"]
    if expected? and avif not in present, do: :missing_avif
  end

  defp avif_issue(_media, _present, false), do: nil

  defp placeholder_issue(media, true = _original?) do
    if DocumentRenderer.image_source?(media.mime_type) and
         Model.placeholder(media, media.collection_name) != false do
      case get_in(media.responsive_images || %{}, ["original", "placeholder"]) do
        nil -> :missing_placeholder
        %{"data_uri" => data_uri} when is_binary(data_uri) -> outdated_placeholder(data_uri)
        _color_or_none -> nil
      end
    end
  end

  defp placeholder_issue(_media, false), do: nil

  # Only when BlurHash is on (it needs the :image library).
  defp blurhash_issue(media, true = _original?) do
    if image?(media) and Config.blurhash_enabled?() and
         not is_binary((media.responsive_images || %{})["blurhash"]),
       do: :missing_blurhash
  end

  defp blurhash_issue(_media, false), do: nil

  # Placeholders from 0.8 are JPEGs carrying the photo's metadata; a WebP
  # one with alpha was made from an image with transparency, which now
  # gets none. Both are read from the record, without opening the image.
  defp outdated_placeholder("data:image/webp;base64," <> data) do
    case Base.decode64(data) do
      {:ok, webp} -> if webp_alpha?(webp), do: :outdated_placeholder
      :error -> :outdated_placeholder
    end
  end

  defp outdated_placeholder(_jpeg_or_other), do: :outdated_placeholder

  # Extended format: the VP8X flags byte has an alpha bit (0x10).
  defp webp_alpha?(
         <<"RIFF", _::binary-size(4), "WEBP", "VP8X", _::binary-size(4), flags, _::binary>>
       ),
       do: Bitwise.band(flags, 0x10) != 0

  # Lossless: the alpha_is_used bit follows the 14-bit width and height.
  defp webp_alpha?(
         <<"RIFF", _::binary-size(4), "WEBP", "VP8L", _::binary-size(4), 0x2F, _, _, _, b4,
           _::binary>>
       ),
       do: Bitwise.band(b4, 0x10) != 0

  defp webp_alpha?(_lossy), do: false

  defp responsive_issue(media, present, true = _original?) do
    if image?(media) and Model.responsive?(media, media.collection_name) do
      paths = ResponsiveImages.paths(media, nil)

      if paths == [] or Enum.any?(paths, &(&1 not in present)), do: :missing_responsive
    end
  end

  defp responsive_issue(_media, _present, false), do: nil

  # Dimensions are only read with an image processor; without one (an app
  # without :image) no repair could add them.
  defp metadata_issue(media) do
    if image?(media) and PhxMediaLibrary.ImageProcessor.available?() and
         not Map.has_key?(media.metadata || %{}, "width"),
       do: :missing_metadata
  end

  defp name_issue(media) do
    unless Pipeline.named?(media, Model.file_naming(media, media.collection_name)),
      do: :needs_rename
  end

  defp drop_issue(media, original?) do
    if original? and Pipeline.webp_served?(media) and
         not Keyword.get(Model.webp_settings(media, media.collection_name), :keep_original, true),
       do: :original_not_dropped
  end

  defp image?(media), do: String.starts_with?(media.mime_type || "", "image/")
end
