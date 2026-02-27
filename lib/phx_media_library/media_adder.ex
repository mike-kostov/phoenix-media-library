defmodule PhxMediaLibrary.MediaAdder do
  @moduledoc """
  Builder struct for adding media to a model.

  This module provides a fluent API for configuring media before
  it is persisted to storage and the database.

  You typically won't use this module directly - instead use the
  functions in `PhxMediaLibrary` which delegate here.
  """

  alias PhxMediaLibrary.{
    Collection,
    Config,
    Media,
    MimeDetector,
    PathGenerator,
    StorageWrapper,
    Telemetry
  }

  defstruct [
    :model,
    :source,
    :custom_filename,
    :custom_properties,
    :generate_responsive,
    :disk
  ]

  @type source :: Path.t() | {:url, String.t()} | map()

  @type t :: %__MODULE__{
          model: Ecto.Schema.t(),
          source: source(),
          custom_filename: String.t() | nil,
          custom_properties: map(),
          generate_responsive: boolean(),
          disk: atom() | nil
        }

  @doc """
  Create a new MediaAdder for the given model and source.
  """
  @spec new(Ecto.Schema.t(), source()) :: t()
  def new(model, source) do
    %__MODULE__{
      model: model,
      source: source,
      custom_properties: %{},
      generate_responsive: false
    }
  end

  @doc """
  Set a custom filename.
  """
  @spec using_filename(t(), String.t()) :: t()
  def using_filename(%__MODULE__{} = adder, filename) do
    %{adder | custom_filename: filename}
  end

  @doc """
  Set custom properties.
  """
  @spec with_custom_properties(t(), map()) :: t()
  def with_custom_properties(%__MODULE__{} = adder, properties) when is_map(properties) do
    %{adder | custom_properties: Map.merge(adder.custom_properties, properties)}
  end

  @doc """
  Enable responsive image generation.
  """
  @spec with_responsive_images(t()) :: t()
  def with_responsive_images(%__MODULE__{} = adder) do
    %{adder | generate_responsive: true}
  end

  @doc """
  Finalize and persist the media.
  """
  @spec to_collection(t(), atom(), keyword()) :: {:ok, Media.t()} | {:error, term()}
  def to_collection(%__MODULE__{} = adder, collection_name, opts \\ []) do
    telemetry_metadata = %{
      collection: collection_name,
      source_type: source_type(adder.source),
      model: adder.model
    }

    Telemetry.span([:phx_media_library, :add], telemetry_metadata, fn ->
      result =
        with {:ok, file_info} <- resolve_source(adder),
             {:ok, file_info, file_content} <- read_and_detect_mime(file_info),
             {:ok, _validated} <- validate_collection(adder, collection_name, file_info),
             :ok <- maybe_verify_content_type(adder, collection_name, file_info, file_content),
             {:ok, media} <-
               store_and_persist(adder, collection_name, file_info, file_content, opts) do
          # Trigger async conversion processing
          maybe_process_conversions(adder.model, media, collection_name)
          {:ok, media}
        end

      stop_metadata =
        case result do
          {:ok, media} -> %{media: media}
          {:error, reason} -> %{error: reason}
        end

      {result, stop_metadata}
    end)
  end

  # Private functions

  defp resolve_source(%__MODULE__{source: source, custom_filename: custom_filename}) do
    case source do
      {:url, url} ->
        download_from_url(url, custom_filename)

      path when is_binary(path) ->
        resolve_file_path(path, custom_filename)

      # Plug.Upload must come before generic map pattern
      %Plug.Upload{path: path, filename: original_filename} ->
        resolve_file_path(path, custom_filename || original_filename)

      # Phoenix.LiveView.UploadEntry or similar map with path/filename
      %{path: path, filename: original_filename} ->
        resolve_file_path(path, custom_filename || original_filename)

      _ ->
        {:error, :invalid_source}
    end
  end

  defp download_from_url(url, custom_filename) do
    case Req.get(url, decode_body: false) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        filename = custom_filename || filename_from_url(url, headers)
        mime_type = get_content_type(headers) || MIME.from_path(filename)

        temp_path = write_temp_file(body, filename)

        {:ok,
         %{
           path: temp_path,
           filename: filename,
           mime_type: mime_type,
           size: byte_size(body),
           temp: true
         }}

      {:ok, %{status: status}} ->
        {:error, {:download_failed, status}}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  defp resolve_file_path(path, custom_filename) do
    with {:ok, stat} <- File.stat(path) do
      filename = custom_filename || Path.basename(path)
      mime_type = MIME.from_path(filename)

      {:ok,
       %{
         path: path,
         filename: filename,
         mime_type: mime_type,
         size: stat.size,
         temp: false
       }}
    end
  end

  defp validate_collection(%__MODULE__{model: model}, collection_name, file_info) do
    case get_collection_config(model, collection_name) do
      nil ->
        # No explicit collection config - allow any file
        {:ok, :no_config}

      %Collection{} = config ->
        with :ok <- validate_mime_type(config, file_info),
             :ok <- validate_file_size(config, file_info) do
          {:ok, config}
        end
    end
  end

  defp validate_mime_type(%Collection{accepts: accepts}, file_info)
       when is_list(accepts) and accepts != [] do
    if file_info.mime_type in accepts do
      :ok
    else
      {:error, {:invalid_mime_type, file_info.mime_type, accepts}}
    end
  end

  defp validate_mime_type(_config, _file_info), do: :ok

  defp validate_file_size(%Collection{max_size: max_size}, file_info)
       when is_integer(max_size) and max_size > 0 do
    if file_info.size <= max_size do
      :ok
    else
      {:error, {:file_too_large, file_info.size, max_size}}
    end
  end

  defp validate_file_size(_config, _file_info), do: :ok

  # Read file content and upgrade MIME type using content-based detection.
  # This reads the file once; the content is then threaded through the rest
  # of the pipeline to avoid a second read.
  defp read_and_detect_mime(file_info) do
    file_content = File.read!(file_info.path)
    detected_mime = MimeDetector.detect_with_fallback(file_content, file_info.filename)
    {:ok, %{file_info | mime_type: detected_mime}, file_content}
  end

  # Verify that file content matches the declared MIME type, if the
  # collection has `verify_content_type: true` (the default).
  defp maybe_verify_content_type(
         %__MODULE__{model: model},
         collection_name,
         file_info,
         file_content
       ) do
    case get_collection_config(model, collection_name) do
      %Collection{verify_content_type: false} ->
        :ok

      _ ->
        # verify_content_type defaults to true when nil or true
        MimeDetector.verify(file_content, file_info.filename, file_info.mime_type)
    end
  end

  defp store_and_persist(%__MODULE__{} = adder, collection_name, file_info, file_content, opts) do
    uuid = generate_uuid()
    disk = opts[:disk] || adder.disk || get_default_disk(adder.model, collection_name)
    storage = Config.storage_adapter(disk)

    # Compute checksum before storage for integrity verification
    checksum = Media.compute_checksum(file_content, "sha256")

    # Build media attributes
    attrs = %{
      uuid: uuid,
      collection_name: to_string(collection_name),
      name: sanitize_name(file_info.filename),
      file_name: file_info.filename,
      mime_type: file_info.mime_type,
      disk: to_string(disk),
      size: file_info.size,
      custom_properties: adder.custom_properties,
      mediable_type: get_mediable_type(adder.model),
      mediable_id: adder.model.id,
      order_column: get_next_order(adder.model, collection_name),
      checksum: checksum,
      checksum_algorithm: "sha256"
    }

    # Determine storage path
    storage_path = PathGenerator.for_new_media(attrs)

    # Store the file
    with :ok <- StorageWrapper.put(storage, storage_path, file_content),
         {:ok, media} <- insert_media(attrs) do
      # Handle single file collections
      maybe_cleanup_collection(adder.model, collection_name, media)

      # Generate responsive images if requested
      media =
        if adder.generate_responsive and image?(file_info.mime_type) do
          generate_responsive_images(media)
        else
          media
        end

      # Cleanup temp file if needed
      if file_info.temp, do: File.rm(file_info.path)

      {:ok, media}
    end
  end

  defp image?(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp generate_responsive_images(media) do
    case PhxMediaLibrary.ResponsiveImages.generate(media, nil) do
      {:ok, responsive_data} ->
        {:ok, updated} =
          media
          |> Ecto.Changeset.change(responsive_images: responsive_data)
          |> Config.repo().update()

        updated

      {:error, _reason} ->
        # Log error but don't fail the upload
        media
    end
  end

  defp insert_media(attrs) do
    %Media{}
    |> Media.changeset(attrs)
    |> Config.repo().insert()
  end

  defp maybe_process_conversions(model, media, collection_name) do
    conversions = get_conversions_for(model, collection_name)

    if conversions != [] do
      Config.async_processor().process_async(media, conversions)
    end
  end

  # Helper functions

  defp generate_uuid, do: Ecto.UUID.generate()

  defp sanitize_name(filename) do
    filename
    |> Path.rootname()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp get_mediable_type(model) do
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
  end

  defp get_collection_config(model, collection_name) do
    if function_exported?(model.__struct__, :get_media_collection, 1) do
      model.__struct__.get_media_collection(collection_name)
    end
  end

  defp get_conversions_for(model, collection_name) do
    if function_exported?(model.__struct__, :get_media_conversions, 1) do
      model.__struct__.get_media_conversions(collection_name)
    else
      []
    end
  end

  defp get_default_disk(model, collection_name) do
    case get_collection_config(model, collection_name) do
      %Collection{disk: disk} when not is_nil(disk) -> disk
      _ -> Config.default_disk()
    end
  end

  defp get_next_order(model, collection_name) do
    # Get highest order_column and add 1
    model
    |> Media.for_model(collection_name)
    |> Enum.map(& &1.order_column)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp maybe_cleanup_collection(model, collection_name, new_media) do
    case get_collection_config(model, collection_name) do
      %Collection{single_file: true} ->
        model
        |> Media.for_model(collection_name)
        |> Enum.reject(&(&1.id == new_media.id))
        |> Enum.each(&Media.delete/1)

      %Collection{max_files: max} when is_integer(max) ->
        all_media = Media.for_model(model, collection_name)

        if length(all_media) > max do
          # Items are ordered by order_column ASC (oldest first).
          # Keep the newest `max` items, delete the oldest excess.
          excess_count = length(all_media) - max

          all_media
          |> Enum.take(excess_count)
          |> Enum.each(&Media.delete/1)
        end

      _ ->
        :ok
    end
  end

  defp filename_from_url(url, headers) do
    # Try Content-Disposition first, then fall back to URL path
    case get_content_disposition_filename(headers) do
      nil -> url |> URI.parse() |> Map.get(:path, "") |> Path.basename()
      filename -> filename
    end
  end

  defp get_content_disposition_filename(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-disposition" end)
    |> case do
      {_, value} ->
        Regex.run(~r/filename="?([^"]+)"?/, value, capture: :all_but_first)
        |> case do
          [filename] -> filename
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, value} -> value |> String.split(";") |> List.first() |> String.trim()
      _ -> nil
    end
  end

  defp write_temp_file(content, filename) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "phx_media_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    path
  end

  defp source_type({:url, _}), do: :url
  defp source_type(%Plug.Upload{}), do: :upload
  defp source_type(%{path: _, filename: _}), do: :upload_entry
  defp source_type(path) when is_binary(path), do: :path
  defp source_type(_), do: :unknown
end
