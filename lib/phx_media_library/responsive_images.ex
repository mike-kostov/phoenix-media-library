defmodule PhxMediaLibrary.ResponsiveImages do
  alias PhxMediaLibrary.StorageWrapper

  @moduledoc """
  Generates responsive image variants for optimal loading across devices.

  Responsive images are generated at multiple widths, allowing browsers to
  select the most appropriate size based on the viewport and device pixel ratio.

  ## How It Works

  When responsive images are enabled for a media item:

  1. The original image dimensions are analyzed
  2. Multiple smaller versions are generated at configured breakpoints
  3. All variant information is stored in the `responsive_images` field

  Placeholders are a step of their own, `PhxMediaLibrary.Pipeline.placeholder/2`.

  ## Configuration

      config :phx_media_library,
        responsive_images: [
          enabled: true,
          widths: [320, 640, 960, 1280, 1920]
        ]

  ## Usage in Templates

      # Get srcset for use in img tag
      srcset = PhxMediaLibrary.srcset(media)

      # In HEEx template
      <img
        src={PhxMediaLibrary.url(media)}
        srcset={PhxMediaLibrary.srcset(media)}
        sizes="(max-width: 768px) 100vw, 50vw"
        alt="Description"
      />

  """

  alias PhxMediaLibrary.{Config, LocalSource, Media, Model, PathGenerator, UrlGenerator}

  @typedoc """
  What `responsive_images` stores per source (`"original"` or a conversion
  name): the variants' widths, the full-size file's dimensions and the
  variants' format. Paths are derived from the media, like conversion
  paths (spec 02, C6); `variants/2` expands them. Media from before 0.10
  stores `%{"variants" => [%{"width", "height", "path"}]}`, which still
  reads.
  """
  @type responsive_data :: %{
          String.t() => %{
            String.t() => [pos_integer()] | pos_integer() | [String.t()]
          }
        }

  @doc """
  Generate responsive image variants for a media item.

  Returns updated responsive_images data to be stored on the media record.
  """
  @spec generate(Media.t(), atom() | nil, keyword()) ::
          {:ok, responsive_data()} | {:error, term()}
  def generate(%Media{} = media, conversion \\ nil, opts \\ []) do
    # Remote storage (S3) has no local path; LocalSource fetches a temp copy.
    LocalSource.with_path(media, conversion, &generate_from(media, conversion, opts, &1))
  end

  defp generate_from(media, conversion, opts, source_path) do
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)
    widths = Keyword.get(opts, :widths) || Config.responsive_image_widths()

    with {:ok, image} <- processor.open(source_path),
         {:ok, orig_dims} <- processor.dimensions(image) do
      # The served full-size file may be a capped WebP (webp: [max_dimension:]);
      # variants wider than it would upscale, and the srcset's largest
      # descriptor must carry the served size, not the source's.
      {orig_width, orig_height} = served_dimensions(media, conversion, orig_dims)

      formats = variant_formats(media, conversion)

      reuses_original? =
        conversion != nil and same_shape_as_original?(media, orig_width, orig_height) and
          formats(media, nil) == Enum.map(formats, &elem(&1, 0))

      variants =
        if reuses_original?,
          do: [],
          else:
            generate_variants(
              media,
              image,
              {orig_width, orig_height},
              conversion,
              formats,
              {processor, storage},
              widths
            )

      data = build_responsive_data(variants, orig_width, orig_height, conversion, formats)

      {:ok, if(reuses_original?, do: mark_reuse(data, conversion), else: data)}
    end
  end

  @doc """
  Generate responsive variants for all conversions of a media item.
  """
  @spec generate_all(Media.t()) :: {:ok, responsive_data()} | {:error, term()}
  def generate_all(%Media{} = media) do
    with {:ok, original_data} <- generate(media, nil) do
      conversion_data = generate_conversion_data(media)
      {:ok, Map.merge(original_data, conversion_data)}
    end
  end

  @doc """
  The formats (extensions) the variants of the original (`nil`) or a
  conversion come in, in priority order; `[]` when there are none.

  ## Examples

      PhxMediaLibrary.ResponsiveImages.formats(media, nil)
      #=> ["avif", "webp"]

  """
  @spec formats(Media.t(), atom() | String.t() | nil) :: [String.t()]
  def formats(%Media{responsive_images: responsive} = media, conversion) do
    case (responsive || %{})[conversion_key(conversion)] do
      %{"widths" => _, "formats" => formats} -> formats
      _ -> media |> variants(conversion) |> Enum.map(&extension(&1["path"])) |> Enum.uniq()
    end
  end

  @doc """
  The stored variants of the original (`nil`) or a conversion in `format`
  (an extension, default the last of `formats/2`), each
  `%{"width", "height", "path"}`, the full-size file last; `[]` when there
  are none. Reads both the compact shape and the one from before 0.10.

  ## Examples

      PhxMediaLibrary.ResponsiveImages.variants(media, nil)
      #=> [%{"width" => 320, "height" => 240, "path" => ".../responsive/photo_320w.webp"},
      #=>  %{"width" => 1600, "height" => 1200, "path" => ".../photo.webp"}]

      PhxMediaLibrary.ResponsiveImages.variants(media, :preview, "avif")

  """
  @spec variants(Media.t(), atom() | String.t() | nil, String.t() | nil) :: [map()]
  def variants(%Media{responsive_images: responsive} = media, conversion, format \\ nil) do
    case (responsive || %{})[conversion_key(conversion)] do
      %{"widths" => widths, "width" => width, "height" => height, "formats" => [_ | _] = formats} ->
        ext = format || List.last(formats)
        if ext in formats, do: expand(media, conversion, widths, {width, height}, ext), else: []

      %{"variants" => variants} when is_list(variants) ->
        legacy(media, conversion, variants, format)

      # The shape before 0.8: a bare list.
      variants when is_list(variants) ->
        legacy(media, conversion, variants, format)

      _ ->
        []
    end
  end

  @doc """
  The paths of every variant of the original (`nil`) or a conversion, in
  every format, full-size files included.

  ## Examples

      PhxMediaLibrary.ResponsiveImages.paths(media, nil)

  """
  @spec paths(Media.t(), atom() | String.t() | nil) :: [String.t()]
  def paths(%Media{} = media, conversion) do
    for format <- formats(media, conversion),
        %{"path" => path} <- variants(media, conversion, format),
        do: path
  end

  defp legacy(media, conversion, variants, format) do
    variants = Enum.filter(variants, &is_map/1)

    if format == nil or format in formats(media, conversion), do: variants, else: []
  end

  defp expand(media, conversion, widths, {width, height}, ext) do
    for(
      w <- widths,
      do: %{
        "width" => w,
        "height" => round(w * height / width),
        "path" => responsive_variant_path(media, conversion, w, dot(ext))
      }
    ) ++
      [
        %{
          "width" => width,
          "height" => height,
          "path" => full_size_path(media, conversion, ext)
        }
      ]
  end

  defp dot(""), do: ""
  defp dot(ext), do: "." <> ext

  # The full-size file in the variants' format: the original's AVIF or WebP
  # sibling, or a conversion's file in that format.
  defp full_size_path(media, nil, ext) do
    case (media.custom_properties || %{})[ext] do
      path when is_binary(path) -> path
      _ -> PathGenerator.relative_path(media, nil)
    end
  end

  defp full_size_path(media, conversion, ext) do
    media
    |> PathGenerator.conversion_paths(conversion)
    |> Enum.find(PathGenerator.relative_path(media, conversion), &(Path.extname(&1) == dot(ext)))
  end

  @doc """
  Build a srcset string from responsive image data.
  """
  @spec build_srcset(Media.t(), atom() | nil) :: String.t() | nil
  def build_srcset(%Media{responsive_images: responsive} = media, conversion \\ nil) do
    key = conversion_key(conversion)

    case variants(media, conversion) do
      [] ->
        nil

      variants ->
        srcset_parts =
          variants
          |> Enum.sort_by(& &1["width"])
          |> Enum.map(fn %{"width" => width, "path" => path} ->
            url = UrlGenerator.url_for_path(media, path)
            "#{url} #{width}w"
          end)

        # Add placeholder as smallest if available
        placeholder_part =
          case get_in(responsive, [key, "placeholder", "data_uri"]) do
            nil -> []
            data_uri -> ["#{data_uri} 32w"]
          end

        (placeholder_part ++ srcset_parts)
        |> Enum.join(", ")
    end
  end

  @doc """
  Get the tiny placeholder data URI for progressive loading.
  """
  @spec placeholder(Media.t(), atom() | nil) :: String.t() | nil
  def placeholder(%Media{responsive_images: responsive}, conversion \\ nil) do
    key = conversion_key(conversion)
    get_in(responsive, [key, "placeholder", "data_uri"])
  end

  @doc """
  Get placeholder dimensions for proper aspect ratio.
  """
  @spec placeholder_dimensions(Media.t(), atom() | nil) :: {integer(), integer()} | nil
  def placeholder_dimensions(%Media{responsive_images: responsive}, conversion \\ nil) do
    key = conversion_key(conversion)

    case get_in(responsive, [key, "placeholder"]) do
      %{"width" => w, "height" => h} -> {w, h}
      _ -> nil
    end
  end

  # Private functions

  # One width, resized once and stored in every format. A width counts only
  # when all its formats are stored; otherwise its files are removed.
  defp generate_variant(
         media,
         image,
         width,
         {orig_width, orig_height},
         conversion,
         formats,
         {processor, storage}
       ) do
    height = round(width * orig_height / orig_width)

    resize = %PhxMediaLibrary.Conversion{
      name: :responsive,
      width: width,
      height: height,
      fit: :contain
    }

    with {:ok, resized} <- processor.apply_conversion(image, resize) do
      paths =
        for {ext, quality} <- formats,
            do: {responsive_variant_path(media, conversion, width, dot(ext)), quality}

      case store_variants(resized, paths, processor, storage) do
        :ok ->
          {:ok, width}

        error ->
          remove(storage, paths)
          error
      end
    end
  end

  defp store_variants(_image, [], _processor, _storage), do: :ok

  defp store_variants(image, [{path, quality} | rest], processor, storage) do
    with :ok <- store_variant(image, path, quality, processor, storage),
         do: store_variants(image, rest, processor, storage)
  end

  defp remove(storage, paths),
    do: Enum.each(paths, fn {path, _quality} -> StorageWrapper.delete(storage, path) end)

  # The image processor picks its encoder from the extension.
  defp store_variant(image, path, quality, processor, storage) do
    temp_path = temp_file_path(path)

    try do
      with {:ok, _} <-
             processor.save(
               image,
               temp_path,
               Enum.reject([quality: quality], &is_nil(elem(&1, 1)))
             ),
           {:ok, content} <- File.read(temp_path) do
        StorageWrapper.put(storage, path, content)
      end
    after
      File.rm(temp_path)
    end
  end

  defp responsive_variant_path(media, conversion, width, ext) do
    # Derive the variant directory from the configured path generator so
    # variants live beside the original. This respects custom/tenant/date
    # generators and stringifies a non-binary mediable_id, instead of assuming
    # the default `{type}/{id}/{uuid}` layout.
    base_path =
      media
      |> PathGenerator.relative_path(nil)
      |> Path.dirname()
      |> Path.join("responsive")

    base_name = Path.rootname(media.file_name)

    filename =
      if conversion do
        "#{base_name}_#{conversion}_#{width}w#{ext}"
      else
        "#{base_name}_#{width}w#{ext}"
      end

    Path.join(base_path, filename)
  end

  # The formats a source's variants come in, in priority order, each with
  # its quality (spec 02, F1). A conversion's are the formats it was made
  # in. The original's are the listed formats it has a full-size file in
  # (its AVIF, its WebP or itself), so each format's srcset ends with the
  # full size; with none, its best one: AVIF, else WebP, else its own
  # (ADR-024).
  defp variant_formats(media, nil) do
    listed = with_extensions(media, Model.formats(media, media.collection_name, media.mime_type))
    available = full_size_formats(media)

    case Enum.filter(listed, fn {ext, _quality} -> ext in available end) do
      [] -> [{hd(available), nil}]
      formats -> formats
    end
  end

  defp variant_formats(media, conversion) do
    listed =
      media
      |> Model.conversions(media.collection_name)
      |> Enum.find(&(to_string(&1.name) == to_string(conversion)))
      |> then(
        &with_extensions(
          media,
          Model.formats(media, media.collection_name, media.mime_type, &1),
          &1
        )
      )
      |> Map.new()

    for path <- PathGenerator.conversion_paths(media, conversion),
        ext = extension(path),
        do: {ext, listed[ext]}
  end

  defp with_extensions(media, formats, conversion \\ nil) do
    for {format, opts} <- formats do
      ext =
        if format == :original,
          do: extension(PathGenerator.relative_path(media, nil)),
          else: to_string(format)

      {ext, opts[:quality] || (conversion && conversion.quality)}
    end
  end

  defp full_size_formats(media) do
    props = media.custom_properties || %{}
    siblings = for ext <- ["avif", "webp"], is_binary(props[ext]), do: ext
    siblings ++ [extension(PathGenerator.relative_path(media, nil))]
  end

  defp extension(path), do: path |> Path.extname() |> String.trim_leading(".")

  defp generate_variants(media, image, {orig_width, _} = dims, conversion, formats, tools, widths) do
    widths
    |> Enum.filter(&(&1 < orig_width))
    |> Enum.map(&generate_variant(media, image, &1, dims, conversion, formats, tools))
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, width} -> width end)
  end

  # The compact shape (see responsive_data/0): the variants' widths and
  # formats, and the full size, whose file in each format is the original's
  # AVIF or WebP sibling, the original, or the conversion's file.
  defp build_responsive_data(widths, orig_width, orig_height, conversion, formats) do
    # Placeholders are their own step (Pipeline.placeholder/2).
    %{
      conversion_key(conversion) => %{
        "widths" => widths,
        "width" => orig_width,
        "height" => orig_height,
        "formats" => Enum.map(formats, &elem(&1, 0))
      }
    }
  end

  defp generate_conversion_data(media) do
    media.generated_conversions
    |> Map.keys()
    |> Enum.map(&generate_single_conversion_data(media, &1))
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp generate_single_conversion_data(media, conversion_name) do
    case generate(media, conversion_name) do
      {:ok, data} -> data
      _ -> %{}
    end
  end

  # A conversion with the original's shape (within a pixel of rounding) gets
  # no variants of its own: its srcset reuses the original's (ADR-024). Only
  # when the original has variants to reuse.
  defp same_shape_as_original?(media, width, height) do
    variants = variants(media, nil)

    case Enum.max_by(variants, &(&1["width"] || 0), fn -> nil end) do
      %{"width" => ow, "height" => oh} when is_integer(ow) and is_integer(oh) and ow > 0 ->
        length(variants) > 1 and abs(round(width * oh / ow) - height) <= 1

      _ ->
        false
    end
  end

  defp mark_reuse(data, conversion),
    do: update_in(data, [conversion_key(conversion)], &Map.put(&1, "reuses", "original"))

  defp served_dimensions(
         %Media{custom_properties: %{"webp_width" => w, "webp_height" => h}},
         nil,
         _
       )
       when is_integer(w) and is_integer(h),
       do: {w, h}

  defp served_dimensions(_media, _conversion, dims), do: dims

  defp conversion_key(nil), do: "original"
  defp conversion_key(conversion), do: to_string(conversion)

  defp temp_file_path(path) do
    dir = System.tmp_dir!()
    filename = Path.basename(path)
    Path.join(dir, "phx_media_responsive_#{:erlang.unique_integer([:positive])}_#{filename}")
  end
end
