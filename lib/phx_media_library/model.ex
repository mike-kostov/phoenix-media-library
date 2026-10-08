defmodule PhxMediaLibrary.Model do
  @moduledoc """
  Reads media settings from a model and keeps its collections within their
  limits. A model is an Ecto schema that `use`s `PhxMediaLibrary.HasMedia`.

  This is the one place that answers "what are the settings for this
  media?": mediable type, collection and conversion definitions, default
  disk, and the resolved WebP, responsive-image and pixel-limit settings.
  Uploads (`MediaAdder`, direct uploads, LiveView helpers) and repairs (mix
  tasks, `PhxMediaLibrary.Pipeline`) all ask here, so they can't drift apart.

  Functions taking a `target` accept a model struct (`%MyApp.Post{}`), a
  model module (`MyApp.Post`), or a `PhxMediaLibrary.Media` record, whose
  model is found through `PhxMediaLibrary.ModelRegistry`. Collection names
  may be atoms or strings.

      PhxMediaLibrary.Model.webp_settings(post, :images)[:enabled]  #=> true
      PhxMediaLibrary.Model.placeholder(media, media.collection_name) #=> :blur
  """

  import Ecto.Query, only: [from: 2]

  alias PhxMediaLibrary.{Collection, Config, Conversion, Media, ModelRegistry}

  @typedoc "A model struct, a model module, or a media record."
  @type target :: struct() | module()

  @doc """
  The polymorphic type stored in `mediable_type` for this model.

  Uses `__media_type__/0` from `HasMedia` (the table name by default). For
  other schemas it falls back to the Ecto table name, then to the
  underscored module name.

  ## Examples

      PhxMediaLibrary.Model.mediable_type(%MyApp.Post{})
      #=> "posts"

  """
  @spec mediable_type(struct()) :: String.t()
  def mediable_type(%module{}) do
    cond do
      function_exported?(module, :__media_type__, 0) -> module.__media_type__()
      function_exported?(module, :__schema__, 1) -> module.__schema__(:source)
      true -> module |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  @doc """
  The collection definition for `collection_name` (atom or string), or `nil`
  when the model doesn't define it.

  ## Examples

      PhxMediaLibrary.Model.collection(post, :images)
      #=> %PhxMediaLibrary.Collection{name: :images, ...}

  """
  @spec collection(target(), atom() | String.t()) :: Collection.t() | nil
  def collection(target, collection_name) do
    module = model_module(target)

    if module && function_exported?(module, :media_collections, 0) do
      name = to_string(collection_name)
      Enum.find(module.media_collections(), &(to_string(&1.name) == name))
    end
  end

  @doc """
  The conversions that apply to `collection_name`.

  ## Examples

      PhxMediaLibrary.Model.conversions(post, :images)
      #=> [%PhxMediaLibrary.Conversion{name: :thumb, ...}]

  """
  @spec conversions(target(), atom() | String.t()) :: [Conversion.t()]
  def conversions(target, collection_name) do
    module = model_module(target)

    if module && function_exported?(module, :media_conversions, 0) do
      name = to_string(collection_name)

      Enum.filter(module.media_conversions(), fn %Conversion{collections: collections} ->
        collections == [] or Enum.any?(collections, &(to_string(&1) == name))
      end)
    else
      []
    end
  end

  @doc """
  The model module behind a target, or `nil` when a media record's
  `mediable_type` matches no known model.

  ## Examples

      PhxMediaLibrary.Model.model_module(media)
      #=> MyApp.Post

  """
  @spec model_module(target()) :: module() | nil
  def model_module(%Media{mediable_type: type}) do
    case ModelRegistry.find_model_module(type) do
      {:ok, module} -> module
      :error -> nil
    end
  end

  def model_module(%module{}), do: module
  def model_module(module) when is_atom(module), do: module

  @doc """
  Resolved WebP settings for a collection: its `webp:` override merged over
  the global `:webp` config (see `PhxMediaLibrary.Config.resolve_webp/1`).
  A `formats:` list that includes `:webp`, set on the collection or
  globally, turns it on too, unless `webp:` is off at that level or a more
  specific one.

  ## Examples

      PhxMediaLibrary.Model.webp_settings(media, media.collection_name)
      #=> [enabled: true, quality: 82, keep_original: true, max_dimension: nil]

  """
  @spec webp_settings(target(), atom() | String.t()) :: keyword()
  def webp_settings(target, collection_name) do
    copy_settings(target, collection_name, :webp, &Config.resolve_webp/1)
  end

  @doc """
  Resolved AVIF settings for a collection: its `avif:` override merged over
  the global config (see `PhxMediaLibrary.Config.resolve_avif/1`). A
  `formats:` list that includes `:avif` turns it on too, as for
  `webp_settings/2`.

  ## Examples

      PhxMediaLibrary.Model.avif_settings(post, :photos)
      #=> [enabled: true, quality: nil]

  """
  @spec avif_settings(target(), atom() | String.t()) :: keyword()
  def avif_settings(target, collection_name) do
    copy_settings(target, collection_name, :avif, &Config.resolve_avif/1)
  end

  # The original's WebP and AVIF copies: an explicit formats: list (the
  # collection's, else the global one) turns on the copy in each format it
  # lists, so the original's variants come in those formats too (spec 02,
  # F1; Mike, 2026-10-08). webp:/avif: off at the same or a more specific
  # level wins. The library's default [:webp] turns nothing on.
  defp copy_settings(target, collection_name, format, resolve) do
    override = override(target, collection_name, format)
    settings = resolve.(override)

    if not settings[:enabled] and not explicitly_off?(override) and
         listed?(target, collection_name, format),
       do: resolve.(true),
       else: settings
  end

  defp listed?(target, collection_name, format) do
    case collection(target, collection_name) do
      %Collection{formats: [_ | _] = formats} ->
        Keyword.has_key?(formats, format)

      _ ->
        formats = Config.formats()

        formats != nil and Keyword.has_key?(formats, format) and
          not explicitly_off?(Application.get_env(:phx_media_library, format))
    end
  end

  @doc """
  The placeholder images in a collection get: `:blur`, `:color` or `false`
  (see `PhxMediaLibrary.Config.resolve_placeholder/1`).

  ## Examples

      PhxMediaLibrary.Model.placeholder(post, :photos)
      #=> :blur

  """
  @spec placeholder(target(), atom() | String.t()) :: :blur | :color | false
  def placeholder(target, collection_name) do
    Config.resolve_placeholder(override(target, collection_name, :placeholder))[:type]
  end

  @doc """
  The longest side of a collection's `:blur` placeholders, in pixels
  (default 32), whatever the image's orientation.

  ## Examples

      PhxMediaLibrary.Model.placeholder_size(post, :photos)
      #=> 32

  """
  @spec placeholder_size(target(), atom() | String.t()) :: pos_integer()
  def placeholder_size(target, collection_name) do
    Config.resolve_placeholder(override(target, collection_name, :placeholder))[:size]
  end

  @doc """
  The format plain URLs of a collection's conversions carry: the last, safe
  one of `formats/4`, or `nil` for the original's format.

  ## Examples

      PhxMediaLibrary.Model.conversion_format(post, :photos, "image/jpeg")
      #=> :webp

  """
  @spec conversion_format(target(), atom() | String.t(), String.t() | nil) ::
          Conversion.format() | nil
  def conversion_format(target, collection_name, mime_type) do
    case target |> formats(collection_name, mime_type) |> List.last() do
      {:original, _} -> nil
      {format, _} -> format
    end
  end

  @doc """
  The formats a conversion (or, with `nil`, a collection's responsive
  variants) is made in, in priority order: the last is the safe one, which
  plain URLs and `<img>` use.

  The first of these that is set wins:

  1. the conversion's `formats:` (or `format: x`, which is `formats: [x]`)
  2. the collection's `formats:`, else its `avif:` (`avif: true` is
     `[:avif, :webp]`; `avif: false` drops AVIF from the global list)
  3. `config :phx_media_library, formats:`, else the global `avif:`
  4. `[:webp]`

  Files libvips can't convert (SVG, PDF, video) keep their own format,
  `[original: []]`, unless the conversion lists formats itself.

  ## Examples

      PhxMediaLibrary.Model.formats(post, :photos, "image/jpeg")
      #=> [avif: [quality: 50], webp: []]

      PhxMediaLibrary.Model.formats(post, :photos, "image/jpeg", thumb_conversion)
      #=> [webp: []]

  """
  @spec formats(target(), atom() | String.t(), String.t() | nil, Conversion.t() | nil) ::
          Config.formats()
  def formats(target, collection_name, mime_type, conversion \\ nil) do
    cond do
      match?(%Conversion{formats: [_ | _]}, conversion) ->
        conversion.formats

      # A struct built without Conversion.new/2.
      match?(%Conversion{format: f} when f != nil, conversion) ->
        Config.normalize_formats!([conversion.format])

      not convertible?(mime_type) ->
        [original: []]

      true ->
        collection_formats(collection(target, collection_name))
    end
  end

  defp convertible?(mime_type),
    do: PhxMediaLibrary.Webp.convertible?(mime_type) or mime_type == "image/webp"

  defp collection_formats(%Collection{formats: [_ | _] = formats}), do: formats

  defp collection_formats(%Collection{avif: avif}) when not is_nil(avif) do
    settings = Config.resolve_avif(avif)

    if settings[:enabled],
      do: avif_shorthand(settings),
      else: without_avif(global_formats())
  end

  defp collection_formats(_collection), do: global_formats()

  defp global_formats do
    settings = Config.resolve_avif(nil)

    cond do
      formats = Config.formats() -> formats
      settings[:enabled] -> avif_shorthand(settings)
      true -> [webp: []]
    end
  end

  defp avif_shorthand(settings) do
    avif = if settings[:quality], do: [quality: settings[:quality]], else: []
    [avif: avif, webp: []]
  end

  defp without_avif(formats) do
    case Keyword.delete(formats, :avif) do
      [] -> [webp: []]
      formats -> formats
    end
  end

  @doc """
  Resolved responsive-image settings for a collection: its `responsive:`
  override merged over the global config (see
  `PhxMediaLibrary.Config.resolve_responsive/1`).

  ## Examples

      PhxMediaLibrary.Model.responsive_settings(post, :images)[:widths]
      #=> [320, 640, 960, 1280, 1920]

  """
  @spec responsive_settings(target(), atom() | String.t()) :: keyword()
  def responsive_settings(target, collection_name) do
    Config.resolve_responsive(override(target, collection_name, :responsive))
  end

  @doc """
  Whether responsive variants are generated for a collection.

  Responsive images are opt-in: the collection's `responsive:` setting must
  ask for them and the resolved settings must be enabled. The global config
  supplies defaults such as widths but doesn't opt every collection in.

  `requested?` (from `with_responsive_images/1`) asks for them for one
  upload; only an explicit "off", the collection's `responsive: false` or a
  global `responsive_images: [enabled: false]`, still blocks it. Both paths
  need the `:image` library.

  ## Examples

      PhxMediaLibrary.Model.responsive?(post, :gallery)
      #=> true

  """
  @spec responsive?(target(), atom() | String.t(), boolean()) :: boolean()
  def responsive?(target, collection_name, requested? \\ false) do
    override = override(target, collection_name, :responsive)

    cond do
      explicitly_off?(override) ->
        false

      requested? ->
        Keyword.get(Config.responsive_images_config(), :enabled) != false and image_library?()

      true ->
        opted_in?(override) and Keyword.get(Config.resolve_responsive(override), :enabled, false)
    end
  end

  defp explicitly_off?(false), do: true
  defp explicitly_off?(keyword) when is_list(keyword), do: Keyword.get(keyword, :enabled) == false
  defp explicitly_off?(_), do: false

  defp image_library?, do: Code.ensure_loaded?(Image)

  @doc """
  Whether responsive variants are generated for a collection's conversions:
  the same rule as for the original (`responsive?/3`), so only collections
  that set `responsive:` get them (ADR-017; before 0.10, conversions got
  them whenever the global switch was on).

  ## Examples

      PhxMediaLibrary.Model.conversion_responsive?(post, :photos)
      #=> true

  """
  @spec conversion_responsive?(target(), atom() | String.t()) :: boolean()
  def conversion_responsive?(target, collection_name), do: responsive?(target, collection_name)

  @doc """
  The maximum image size in pixels for a collection: its `max_pixels:`, or
  the global `:max_image_pixels` (see
  `PhxMediaLibrary.Config.max_image_pixels/0`).

  ## Examples

      PhxMediaLibrary.Model.max_pixels(post, :images)
      #=> 100_000_000

  """
  @spec max_pixels(target(), atom() | String.t()) :: pos_integer() | :infinity
  def max_pixels(target, collection_name) do
    case collection(target, collection_name) do
      %Collection{max_pixels: max_pixels} when not is_nil(max_pixels) -> max_pixels
      _ -> Config.max_image_pixels()
    end
  end

  @doc """
  How stored filenames are chosen for a collection: its `file_naming:`, or
  the global `:file_naming` (see `PhxMediaLibrary.FileName`).

  ## Examples

      PhxMediaLibrary.Model.file_naming(product, :images)
      #=> :slug

  """
  @spec file_naming(target(), atom() | String.t()) :: PhxMediaLibrary.FileName.strategy()
  def file_naming(target, collection_name) do
    override(target, collection_name, :file_naming) || Config.file_naming()
  end

  defp override(target, collection_name, key) do
    case collection(target, collection_name) do
      %Collection{} = collection -> Map.fetch!(collection, key)
      nil -> nil
    end
  end

  defp opted_in?(true), do: true
  defp opted_in?(keyword) when is_list(keyword), do: Keyword.get(keyword, :enabled, true)
  defp opted_in?(_), do: false

  @doc """
  The disk for `collection_name`: the collection's `disk:` setting, or the
  configured default disk.

  ## Examples

      PhxMediaLibrary.Model.default_disk(post, :images)
      #=> :local

  """
  @spec default_disk(target(), atom() | String.t()) :: atom() | String.t()
  def default_disk(model, collection_name) do
    case collection(model, collection_name) do
      %Collection{disk: disk} when not is_nil(disk) -> disk
      _ -> Config.default_disk()
    end
  end

  @doc """
  Media already preloaded on `model` through its `has_media` associations,
  so callers can skip the database. Uses the collection's own association
  (`has_media(:images)`) when loaded, else the general `has_media()` one.

  Returns `{:ok, media}` or `:not_loaded`. The media is filtered to the
  collection, without trashed media, and ordered like
  `PhxMediaLibrary.get_media/2`.

  ## Examples

      products = Repo.all(Product) |> Repo.preload(:images)
      PhxMediaLibrary.Model.preloaded_media(hd(products), :images)
      #=> {:ok, [%Media{}, ...]}

  """
  @spec preloaded_media(struct(), atom() | String.t() | nil) :: {:ok, [Media.t()]} | :not_loaded
  def preloaded_media(%module{} = model, collection_name) do
    fields = if collection_name, do: [collection_name, :media], else: [:media]

    Enum.find_value(fields, :not_loaded, fn field ->
      with name when is_atom(name) <- media_association(module, field),
           media when is_list(media) <- Map.get(model, name) do
        {:ok, media |> in_collection(collection_name) |> visible() |> sort_media()}
      else
        _ -> nil
      end
    end)
  end

  # The association named `field` (atom or string), when it holds media.
  defp media_association(module, field) do
    if function_exported?(module, :__schema__, 1) do
      Enum.find(module.__schema__(:associations), fn name ->
        to_string(name) == to_string(field) and
          match?(%{related: Media}, module.__schema__(:association, name))
      end)
    end
  end

  defp in_collection(media, nil), do: media

  defp in_collection(media, collection_name) do
    name = to_string(collection_name)
    Enum.filter(media, &(&1.collection_name == name))
  end

  defp visible(media) do
    if Media.soft_deletes_enabled?(), do: Enum.filter(media, &is_nil(&1.deleted_at)), else: media
  end

  defp sort_media(media) do
    Enum.sort_by(media, fn m ->
      {m.order_column || 0, m.inserted_at && DateTime.to_unix(m.inserted_at, :microsecond)}
    end)
  end

  @doc """
  The `order_column` for the next media added to a collection.

  ## Examples

      PhxMediaLibrary.Model.next_order(post, :images)
      #=> 4

  """
  @spec next_order(struct(), atom() | String.t()) :: pos_integer()
  def next_order(model, collection_name) do
    type = mediable_type(model)
    collection_name = to_string(collection_name)

    query =
      from(m in Media,
        where: m.mediable_type == ^type,
        where: m.mediable_id == ^model.id,
        where: m.collection_name == ^collection_name,
        select: max(m.order_column)
      )

    (Config.repo().one(query) || 0) + 1
  end

  @doc """
  Apply a collection's `single_file` and `max_files` limits after
  `new_media` was added, deleting the oldest media beyond the limit.

  Media is ordered by position, then insertion time, then ID. An upload only
  ever deletes media older than the newest it can see, never a newer item.
  So two uploads racing on a `single_file` collection can't delete each
  other: the newer one always survives. In the rare worst case both remain
  until the next upload.

  Deletion goes through `Media.delete/1`, so it respects soft deletes.

  ## Examples

      :ok = PhxMediaLibrary.Model.enforce_collection_limits(post, :avatar, media)

  """
  @spec enforce_collection_limits(struct(), atom(), Media.t()) :: :ok
  def enforce_collection_limits(model, collection_name, %Media{} = new_media) do
    case collection(model, collection_name) do
      %Collection{single_file: true} ->
        new_key = age_key(new_media)

        model
        |> Media.for_model(collection_name)
        |> Enum.filter(&(age_key(&1) < new_key))
        |> Enum.each(&Media.delete/1)

      %Collection{max_files: max} when is_integer(max) and max > 0 ->
        model
        |> Media.for_model(collection_name)
        |> Enum.sort_by(&age_key/1)
        |> Enum.drop(-max)
        |> Enum.each(&Media.delete/1)

      _ ->
        :ok
    end
  end

  # A total order, oldest first. Concurrent uploads can share an
  # order_column and a (second-precision) inserted_at; the ID breaks the tie.
  defp age_key(%Media{} = media) do
    inserted_at = if media.inserted_at, do: DateTime.to_unix(media.inserted_at, :microsecond)
    {media.order_column || 0, inserted_at || 0, media.id}
  end
end
