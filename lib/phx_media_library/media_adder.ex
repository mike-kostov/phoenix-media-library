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
    MetadataExtractor,
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
    :extract_metadata,
    :disk
  ]

  @type source :: Path.t() | {:url, String.t()} | {:url, String.t(), keyword()} | map()

  @type t :: %__MODULE__{
          model: Ecto.Schema.t(),
          source: source(),
          custom_filename: String.t() | nil,
          custom_properties: map(),
          generate_responsive: boolean(),
          extract_metadata: boolean(),
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
      generate_responsive: false,
      extract_metadata: MetadataExtractor.enabled?()
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
  Disable automatic metadata extraction for this media.

  By default, PhxMediaLibrary extracts metadata (dimensions, EXIF, etc.)
  from uploaded files. Use this to skip extraction for a specific upload.

  ## Examples

      post
      |> PhxMediaLibrary.add(upload)
      |> PhxMediaLibrary.without_metadata()
      |> PhxMediaLibrary.to_collection(:images)

  """
  @spec without_metadata(t()) :: t()
  def without_metadata(%__MODULE__{} = adder) do
    %{adder | extract_metadata: false}
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
             {:ok, file_info, header} <- read_and_detect_mime(file_info),
             {:ok, _validated} <- validate_collection(adder, collection_name, file_info),
             :ok <- maybe_verify_content_type(adder, collection_name, file_info, header),
             {:ok, metadata} <- maybe_extract_metadata(adder, file_info),
             {:ok, media} <-
               store_and_persist(adder, collection_name, file_info, metadata, opts) do
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
      {:url, url, url_opts} ->
        download_from_url(url, custom_filename, url_opts)

      {:url, url} ->
        download_from_url(url, custom_filename, [])

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

  defp download_from_url(url, custom_filename, url_opts) do
    with :ok <- validate_url(url) do
      req_opts = build_req_opts(url_opts)

      Telemetry.span(
        [:phx_media_library, :download],
        %{url: url},
        fn -> execute_download(url, custom_filename, req_opts) end
      )
    end
  end

  defp execute_download(url, custom_filename, req_opts) do
    result = do_download(url, custom_filename, req_opts)

    stop_metadata =
      case result do
        {:ok, info} -> %{url: url, size: info.size, mime_type: info.mime_type}
        {:error, reason} -> %{url: url, error: reason}
      end

    {result, stop_metadata}
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:invalid_url, :unsupported_scheme, uri.scheme}}

      is_nil(uri.host) or uri.host == "" ->
        {:error, {:invalid_url, :missing_host}}

      true ->
        :ok
    end
  end

  defp validate_url(_), do: {:error, {:invalid_url, :not_a_string}}

  defp build_req_opts(url_opts) do
    base = [decode_body: false, redirect: true, max_redirects: 5]

    # Allow custom headers (e.g. for authenticated URLs)
    headers = Keyword.get(url_opts, :headers, [])
    timeout = Keyword.get(url_opts, :timeout)

    opts = if headers != [], do: Keyword.put(base, :headers, headers), else: base
    opts = if timeout, do: Keyword.put(opts, :receive_timeout, timeout), else: opts

    opts
  end

  defp do_download(url, custom_filename, req_opts) do
    case Req.get(url, req_opts) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        filename = custom_filename || filename_from_url(url, headers)
        mime_type = get_content_type(headers) || MIME.from_path(filename)

        temp_path = write_temp_file(body, filename)

        {:ok,
         %{
           path: temp_path,
           filename: filename,
           mime_type: mime_type,
           size: byte_size(body),
           temp: true,
           source_url: url
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

  # How many bytes to read for magic-byte MIME detection.
  # TAR signatures live at offset 257, so 512 bytes covers all known formats.
  @mime_header_size 512

  # Read only the file header for MIME detection, avoiding loading the
  # entire file into memory.  The header bytes are also used for
  # content-type verification.  The rest of the file is streamed to
  # storage later, with the checksum computed during the stream.
  defp read_and_detect_mime(file_info) do
    header = read_file_header(file_info.path, @mime_header_size)
    detected_mime = MimeDetector.detect_with_fallback(header, file_info.filename)
    {:ok, %{file_info | mime_type: detected_mime}, header}
  end

  defp read_file_header(path, max_bytes) do
    file = File.open!(path, [:read, :binary])

    try do
      case IO.binread(file, max_bytes) do
        :eof -> <<>>
        data when is_binary(data) -> data
      end
    after
      File.close(file)
    end
  end

  # Verify that file content matches the declared MIME type, if the
  # collection has `verify_content_type: true` (the default).
  # `header` is the first @mime_header_size bytes — enough for magic-byte
  # matching without needing the full file in memory.
  defp maybe_verify_content_type(
         %__MODULE__{model: model},
         collection_name,
         file_info,
         header
       ) do
    case get_collection_config(model, collection_name) do
      %Collection{verify_content_type: false} ->
        :ok

      _ ->
        # verify_content_type defaults to true when nil or true
        MimeDetector.verify(header, file_info.filename, file_info.mime_type)
    end
  end

  # Extract metadata from the file if enabled
  defp maybe_extract_metadata(%__MODULE__{extract_metadata: false}, _file_info) do
    {:ok, %{}}
  end

  defp maybe_extract_metadata(%__MODULE__{}, file_info) do
    MetadataExtractor.extract_metadata(file_info.path, file_info.mime_type)
  end

  defp store_and_persist(
         %__MODULE__{} = adder,
         collection_name,
         file_info,
         metadata,
         opts
       ) do
    uuid = generate_uuid()
    disk = opts[:disk] || adder.disk || get_default_disk(adder.model, collection_name)
    storage = Config.storage_adapter(disk)

    # Build media attributes (checksum is computed during streaming below)
    # Merge source URL into custom_properties if present
    custom_props =
      case file_info do
        %{source_url: url} when is_binary(url) ->
          Map.put(adder.custom_properties, "source_url", url)

        _ ->
          adder.custom_properties
      end

    attrs = %{
      uuid: uuid,
      collection_name: to_string(collection_name),
      name: sanitize_name(file_info.filename),
      file_name: file_info.filename,
      mime_type: file_info.mime_type,
      disk: to_string(disk),
      size: file_info.size,
      custom_properties: custom_props,
      metadata: metadata,
      mediable_type: get_mediable_type(adder.model),
      mediable_id: adder.model.id,
      order_column: get_next_order(adder.model, collection_name)
    }

    # Determine storage path
    storage_path = PathGenerator.for_new_media(attrs)

    # Stream file to storage while computing checksum in a single pass.
    # This avoids loading the entire file into memory.
    with {:ok, checksum} <- stream_and_checksum(storage, storage_path, file_info.path),
         attrs = Map.merge(attrs, %{checksum: checksum, checksum_algorithm: "sha256"}),
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

  # Stream a file to storage while computing its SHA-256 checksum in a
  # single pass.  Each chunk is fed to both the storage adapter (via a
  # checksumming stream wrapper) and the running hash state.
  #
  # The 64 KB chunk size balances memory usage and syscall overhead.
  @stream_chunk_size 64 * 1024

  defp stream_and_checksum(storage, storage_path, file_path) do
    # We use a process dictionary key to thread the hash state through the
    # stream because Enum.reduce inside a stream is not composable with
    # StorageWrapper.put which expects {:stream, enumerable}.
    hash_key = {__MODULE__, :hash_state, make_ref()}

    Process.put(hash_key, :crypto.hash_init(:sha256))

    checksumming_stream =
      file_path
      |> File.stream!(@stream_chunk_size)
      |> Stream.map(fn chunk ->
        state = Process.get(hash_key)
        Process.put(hash_key, :crypto.hash_update(state, chunk))
        chunk
      end)

    result = StorageWrapper.put(storage, storage_path, {:stream, checksumming_stream})

    hash_state = Process.delete(hash_key)

    case result do
      :ok ->
        checksum =
          hash_state
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, checksum}

      {:error, _} = error ->
        Process.delete(hash_key)
        error
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

  defp source_type({:url, _, _}), do: :url
  defp source_type({:url, _}), do: :url
  defp source_type(%Plug.Upload{}), do: :upload
  defp source_type(%{path: _, filename: _}), do: :upload_entry
  defp source_type(path) when is_binary(path), do: :path
  defp source_type(_), do: :unknown
end
