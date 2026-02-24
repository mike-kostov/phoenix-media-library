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
  3. A tiny placeholder (32px wide) is generated for progressive loading
  4. All variant information is stored in the `responsive_images` field

  ## Configuration

      config :phx_media_library,
        responsive_images: [
          enabled: true,
          widths: [320, 640, 960, 1280, 1920],
          tiny_placeholder: true
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

  alias PhxMediaLibrary.{Media, Config, PathGenerator, UrlGenerator}

  @type responsive_data :: %{
          String.t() => [
            %{
              width: pos_integer(),
              height: pos_integer(),
              path: String.t()
            }
          ]
        }

  @doc """
  Generate responsive image variants for a media item.

  Returns updated responsive_images data to be stored on the media record.
  """
  @spec generate(Media.t(), atom() | nil) :: {:ok, responsive_data()} | {:error, term()}
  def generate(%Media{} = media, conversion \\ nil) do
    processor = Config.image_processor()
    storage = Config.storage_adapter(media.disk)
    widths = Config.responsive_image_widths()

    # Get the source image path
    source_path = get_source_path(media, conversion)

    with {:ok, image} <- processor.open(source_path),
         {:ok, {orig_width, orig_height}} <- processor.dimensions(image) do
      # Filter widths to only those smaller than original
      target_widths = Enum.filter(widths, &(&1 < orig_width))

      # Generate variants
      variants =
        target_widths
        |> Enum.map(
          &generate_variant(
            media,
            image,
            &1,
            orig_width,
            orig_height,
            conversion,
            processor,
            storage
          )
        )
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, variant} -> variant end)

      # Add original as largest variant
      original_variant = %{
        "width" => orig_width,
        "height" => orig_height,
        "path" => PathGenerator.relative_path(media, conversion)
      }

      all_variants = variants ++ [original_variant]

      # Generate tiny placeholder if enabled
      placeholder =
        if Config.tiny_placeholders_enabled?() do
          case generate_placeholder(image, processor) do
            {:ok, placeholder_data} -> placeholder_data
            _ -> nil
          end
        end

      # Build the responsive data structure
      key = conversion_key(conversion)

      data = %{
        key => %{
          "variants" => all_variants,
          "placeholder" => placeholder
        }
      }

      {:ok, data}
    end
  end

  @doc """
  Generate responsive variants for all conversions of a media item.
  """
  @spec generate_all(Media.t()) :: {:ok, responsive_data()} | {:error, term()}
  def generate_all(%Media{} = media) do
    # Generate for original
    with {:ok, original_data} <- generate(media, nil) do
      # Generate for each conversion
      conversion_data =
        media.generated_conversions
        |> Map.keys()
        |> Enum.map(fn conversion_name ->
          case generate(media, conversion_name) do
            {:ok, data} -> data
            _ -> %{}
          end
        end)
        |> Enum.reduce(%{}, &Map.merge/2)

      {:ok, Map.merge(original_data, conversion_data)}
    end
  end

  @doc """
  Build a srcset string from responsive image data.
  """
  @spec build_srcset(Media.t(), atom() | nil) :: String.t() | nil
  def build_srcset(%Media{responsive_images: responsive} = media, conversion \\ nil) do
    key = conversion_key(conversion)

    case get_in(responsive, [key, "variants"]) do
      nil ->
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

  defp generate_variant(
         media,
         image,
         target_width,
         orig_width,
         orig_height,
         conversion,
         processor,
         storage
       ) do
    # Calculate height maintaining aspect ratio
    target_height = round(target_width * orig_height / orig_width)

    # Create a conversion struct for resizing
    resize_conversion = %PhxMediaLibrary.Conversion{
      name: :responsive,
      width: target_width,
      height: target_height,
      fit: :contain
    }

    # Generate the resized image
    with {:ok, resized} <- processor.apply_conversion(image, resize_conversion) do
      # Build the storage path for this variant
      variant_path = responsive_variant_path(media, conversion, target_width)
      temp_path = temp_file_path(variant_path)

      # Save and upload
      with {:ok, _} <- processor.save(resized, temp_path),
           {:ok, content} <- File.read(temp_path),
           :ok <- StorageWrapper.put(storage, variant_path, content) do
        # Cleanup temp file
        File.rm(temp_path)

        {:ok,
         %{
           "width" => target_width,
           "height" => target_height,
           "path" => variant_path
         }}
      end
    end
  end

  defp generate_placeholder(image, processor) do
    processor.tiny_placeholder(image)
  end

  defp responsive_variant_path(media, conversion, width) do
    base_path =
      Path.join([
        media.mediable_type,
        media.mediable_id,
        media.uuid,
        "responsive"
      ])

    ext = Path.extname(media.file_name)
    base_name = Path.rootname(media.file_name)

    filename =
      if conversion do
        "#{base_name}_#{conversion}_#{width}w#{ext}"
      else
        "#{base_name}_#{width}w#{ext}"
      end

    Path.join(base_path, filename)
  end

  defp get_source_path(media, nil) do
    PathGenerator.full_path(media, nil)
  end

  defp get_source_path(media, conversion) do
    PathGenerator.full_path(media, conversion)
  end

  defp conversion_key(nil), do: "original"
  defp conversion_key(conversion), do: to_string(conversion)

  defp temp_file_path(path) do
    dir = System.tmp_dir!()
    filename = Path.basename(path)
    Path.join(dir, "phx_media_responsive_#{:erlang.unique_integer([:positive])}_#{filename}")
  end
end
