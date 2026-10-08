defmodule PhxMediaLibrary.MediaAdder do
  @moduledoc """
  Builder struct for adding media to a model.

  This module provides a fluent API for configuring media before
  it is persisted to storage and the database.

  You typically won't use this module directly; the functions in
  `PhxMediaLibrary` build it:

      post
      |> PhxMediaLibrary.add(upload)            # a %MediaAdder{}
      |> PhxMediaLibrary.using_filename("Summer dress.jpg")
      |> PhxMediaLibrary.to_collection(:images)
  """

  alias PhxMediaLibrary.{
    Collection,
    Config,
    Downloader,
    FileName,
    Media,
    MetadataExtractor,
    MimeDetector,
    Model,
    PathGenerator,
    Pipeline,
    StorageWrapper,
    Telemetry,
    UrlGenerator
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

  @type source ::
          Path.t()
          | {:url, String.t()}
          | {:url, String.t(), keyword()}
          | {:binary, binary(), String.t()}
          | {:base64, String.t(), String.t()}
          | {:stream, Enumerable.t(), String.t()}
          | map()

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
        with {:ok, file_info} <- resolve_source(adder, collection_name) do
          try do
            add_file(adder, collection_name, file_info, opts)
          after
            # Downloaded temp files go on success and failure alike.
            if file_info.temp, do: File.rm(file_info.path)
          end
        end

      stop_metadata =
        case result do
          {:ok, media} -> %{media: media}
          {:error, reason} -> %{error: reason}
        end

      {result, stop_metadata}
    end)
  end

  @doc """
  Check a file against a collection's rules: its accepted MIME types, its
  maximum size, and (unless the collection sets `verify_content_type: false`)
  that the content matches the type the filename's extension claims.

  Uploads and `PhxMediaLibrary.complete_external_upload/4` both use it, so a
  file is judged the same way however it arrives. `file_info` needs
  `:filename`, `:mime_type` (the type detected from the content) and `:size`;
  `header` is the file's first bytes.

  ## Examples

      MediaAdder.validate_file(post, :documents, %{filename: "a.pdf", mime_type: "application/pdf", size: 1_024}, header)
      #=> :ok

  """
  @spec validate_file(struct(), atom() | String.t(), map(), binary()) :: :ok | {:error, term()}
  def validate_file(model, collection_name, file_info, header) do
    with {:ok, _config} <- validate_collection(model, collection_name, file_info) do
      verify_content_type(model, collection_name, file_info, header)
    end
  end

  # Private functions

  defp add_file(adder, collection_name, file_info, opts) do
    with {:ok, file_info, header} <- read_and_detect_mime(file_info),
         :ok <- validate_file(adder.model, collection_name, file_info, header),
         :ok <- validate_image_size(adder, collection_name, file_info),
         {:ok, metadata} <- maybe_extract_metadata(adder, file_info),
         {:ok, media} <- store_and_persist(adder, collection_name, file_info, metadata, opts) do
      {:ok, process_conversions_and_finalize_webp(adder, media, collection_name)}
    end
  end

  defp resolve_source(%__MODULE__{source: source} = adder, collection_name),
    do: resolve_source(source, adder, collection_name)

  defp resolve_source({:url, url, url_opts}, adder, collection_name),
    do: download_from_url(url, adder, collection_name, url_opts)

  defp resolve_source({:url, url}, adder, collection_name),
    do: download_from_url(url, adder, collection_name, [])

  defp resolve_source(path, adder, _collection_name) when is_binary(path),
    do: resolve_file_path(path, adder.custom_filename)

  defp resolve_source({kind, data, filename}, adder, collection_name)
       when kind in [:binary, :base64, :stream] and is_binary(filename) do
    max_size = collection_max_size(adder, collection_name)

    with {:ok, chunks} <- chunks(kind, data),
         do: write_temp(chunks, adder.custom_filename || filename, max_size)
  end

  # Plug.Upload must come before generic map pattern
  # A map pattern, not %Plug.Upload{}: Plug is optional (apps without it
  # still compile).
  defp resolve_source(%{__struct__: Plug.Upload, path: path, filename: name}, adder, _collection),
    do: resolve_file_path(path, adder.custom_filename || name)

  # Phoenix.LiveView.UploadEntry or similar map with path/filename
  defp resolve_source(%{path: path, filename: name}, adder, _collection),
    do: resolve_file_path(path, adder.custom_filename || name)

  defp resolve_source(_source, _adder, _collection), do: {:error, :invalid_source}

  defp download_from_url(url, adder, collection_name, url_opts) do
    # Cap the download at the collection's max_size unless the caller set one.
    url_opts =
      Keyword.put_new_lazy(url_opts, :max_size, fn ->
        collection_max_size(adder, collection_name)
      end)

    Telemetry.span(
      [:phx_media_library, :download],
      %{url: url},
      fn -> execute_download(url, adder.custom_filename, url_opts) end
    )
  end

  defp execute_download(url, custom_filename, url_opts) do
    result =
      case Downloader.download(url, url_opts) do
        {:ok, info} when is_binary(custom_filename) ->
          {:ok, %{info | filename: FileName.safe(custom_filename)}}

        other ->
          other
      end

    stop_metadata =
      case result do
        {:ok, info} -> %{url: url, size: info.size, mime_type: info.mime_type}
        {:error, reason} -> %{url: url, error: reason}
      end

    {result, stop_metadata}
  end

  defp collection_max_size(adder, collection_name) do
    case Model.collection(adder.model, collection_name) do
      %Collection{max_size: max_size} -> max_size
      _ -> nil
    end
  end

  defp chunks(:binary, data) when is_binary(data), do: {:ok, [data]}
  defp chunks(:stream, enumerable), do: {:ok, enumerable}

  defp chunks(:base64, data) when is_binary(data) do
    with {:ok, decoded} <- decode_base64(data), do: {:ok, [decoded]}
  end

  defp chunks(_kind, _data), do: {:error, :invalid_source}

  # A data URI ("data:image/png;base64,...") or plain base64. The type comes
  # from the bytes, as for any upload, not from the URI.
  defp decode_base64("data:" <> uri) do
    case String.split(uri, ";base64,", parts: 2) do
      [_type, data] -> decode_base64(data)
      _ -> {:error, :invalid_base64}
    end
  end

  defp decode_base64(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  # In-memory content and streams go to a temporary file (removed after the
  # add, like downloads), so the rest of the upload reads a path. A stream
  # stops at the collection's max_size instead of filling the disk.
  defp write_temp(chunks, filename, max_size) do
    path = Path.join(System.tmp_dir!(), "phx_media_source_#{:erlang.unique_integer([:positive])}")

    case open_and_write(path, chunks, max_size) do
      {:ok, {:ok, size}} ->
        filename = FileName.safe(filename)

        {:ok,
         %{
           path: path,
           filename: filename,
           mime_type: MIME.from_path(filename),
           size: size,
           temp: true
         }}

      {:ok, error} ->
        File.rm(path)
        error

      error ->
        error
    end
  end

  # A stream that raises leaves no temporary file behind.
  defp open_and_write(path, chunks, max_size) do
    File.open(path, [:write, :binary], &write_chunks(&1, chunks, max_size))
  rescue
    e ->
      File.rm(path)
      reraise e, __STACKTRACE__
  end

  defp write_chunks(file, chunks, max_size) do
    Enum.reduce_while(chunks, {:ok, 0}, fn chunk, {:ok, size} ->
      size = size + IO.iodata_length(chunk)

      if is_integer(max_size) and size > max_size do
        {:halt, {:error, {:file_too_large, size, max_size}}}
      else
        IO.binwrite(file, chunk)
        {:cont, {:ok, size}}
      end
    end)
  end

  defp resolve_file_path(path, custom_filename) do
    with {:ok, stat} <- File.stat(path) do
      filename = FileName.safe(custom_filename || Path.basename(path))
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

  defp validate_collection(model, collection_name, file_info) do
    case Model.collection(model, collection_name) do
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

  # Reject images that would need too much memory to decode ("pixel floods":
  # a tiny PNG declaring 40000x40000), then images outside the collection's
  # dimension limits. Opening reads only the header, so the checks decode
  # nothing. Files the processor can't open pass through, as before;
  # nothing will decode them either.
  defp validate_image_size(%__MODULE__{model: model}, collection_name, file_info) do
    max_pixels = Model.max_pixels(model, collection_name)
    limits = Model.dimension_limits(model, collection_name)
    processor = Config.image_processor()

    with true <- image?(file_info.mime_type) and (is_integer(max_pixels) or limits != []),
         {:ok, image} <- processor.open(file_info.path),
         {:ok, {width, height}} <- processor.dimensions(image) do
      check_image_size(width, height, max_pixels, limits)
    else
      _ -> :ok
    end
  end

  defp check_image_size(width, height, max_pixels, _limits)
       when is_integer(max_pixels) and width * height > max_pixels,
       do: {:error, {:image_too_large, width * height, max_pixels}}

  defp check_image_size(width, height, _max_pixels, limits) do
    Enum.find_value(limits, :ok, fn
      {:min_width, min} when width < min -> {:error, {:image_too_narrow, width, min}}
      {:min_height, min} when height < min -> {:error, {:image_too_short, height, min}}
      {:max_width, max} when width > max -> {:error, {:image_too_wide, width, max}}
      {:max_height, max} when height > max -> {:error, {:image_too_tall, height, max}}
      _within -> nil
    end)
  end

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
  # `header` is the first @mime_header_size bytes, enough for magic-byte
  # matching without needing the full file in memory.
  defp verify_content_type(model, collection_name, file_info, header) do
    case Model.collection(model, collection_name) do
      %Collection{verify_content_type: false} ->
        :ok

      _ ->
        # verify_content_type defaults to true when nil or true.
        # file_info.mime_type is already the *detected* type, so compare the
        # content against the type the filename's extension claims.
        MimeDetector.verify(header, file_info.filename, MIME.from_path(file_info.filename))
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
    disk = opts[:disk] || adder.disk || Model.default_disk(adder.model, collection_name)
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

    mediable_type = Model.mediable_type(adder.model)

    # The stored name is ours (see FileName); the uploader's name is kept
    # for display only.
    file_name =
      FileName.storage_name(Model.file_naming(adder.model, collection_name), %{
        original: file_info.filename,
        mime_type: file_info.mime_type,
        mediable_type: mediable_type,
        mediable_id: adder.model.id,
        collection_name: collection_name,
        uuid: uuid
      })

    attrs = %{
      uuid: uuid,
      collection_name: to_string(collection_name),
      name: FileName.slug(file_info.filename),
      file_name: file_name,
      mime_type: file_info.mime_type,
      disk: to_string(disk),
      size: file_info.size,
      custom_properties: custom_props,
      metadata: Map.put(metadata, "original_file_name", file_info.filename),
      mediable_type: mediable_type,
      mediable_id: adder.model.id,
      order_column: Model.next_order(adder.model, collection_name)
    }

    # Determine storage path
    storage_path = PathGenerator.for_new_media(attrs)

    # Stream file to storage while computing checksum in a single pass.
    # This avoids loading the entire file into memory.
    with {:ok, checksum} <- stream_and_checksum(storage, storage_path, file_info.path),
         attrs = Map.merge(attrs, %{checksum: checksum, checksum_algorithm: "sha256"}),
         media = struct(Media, Map.put(attrs, :id, record_id(opts))),
         derived = derive(media, adder, file_info),
         {:ok, media} <- insert_or_remove_files(derived, opts[:replacing]) do
      # Handle single file collections
      Model.enforce_collection_limits(adder.model, collection_name, media)
      {:ok, media}
    end
  end

  # The same Pipeline steps repairs use, on the media before it is inserted:
  # each stores its files and returns its changes in the struct
  # (`write: false`), so the row is written once (spec 02, C4). WebP runs
  # first so responsive variants inherit the .webp encoding; the steps read
  # the uploaded temp file.
  defp derive(media, adder, file_info) do
    steps = [model: adder.model, source: file_info.path, write: false]

    media = step(media, Pipeline.webp(media, steps))
    media = step(media, Pipeline.avif(media, steps))

    media =
      if image?(file_info.mime_type) do
        step(
          media,
          Pipeline.responsive(media, [requested: adder.generate_responsive] ++ steps)
        )
      else
        media
      end

    # Generate blurhash placeholder when enabled and Image is available.
    media =
      if image?(file_info.mime_type) and Config.blurhash_enabled?(),
        do: maybe_generate_blurhash(media, file_info.path),
        else: media

    # Poster frame for videos when FFmpeg is available, while the uploaded
    # file is still present.
    if video?(file_info.mime_type),
      do: maybe_generate_poster(media, file_info.path),
      else: media
  end

  # A failed or skipped derivative never fails the upload; the original is
  # still served.
  defp step(_media, {:ok, updated}), do: updated
  defp step(media, _skipped_or_failed), do: media

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
        error
    end
  end

  defp image?(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp video?(mime_type) do
    String.starts_with?(mime_type, "video/")
  end

  defp maybe_generate_poster(media, file_path) do
    processor = Config.video_processor()

    if processor.available?() do
      duration = media.metadata |> Map.get("duration") |> coerce_float()
      offset = min(duration * 0.1, 5.0) |> max(0.0)

      case processor.extract_poster(file_path, offset) do
        {:ok, jpeg_data} -> store_poster(media, jpeg_data)
        {:error, _} -> media
      end
    else
      media
    end
  end

  defp store_poster(media, jpeg_data) do
    storage = Config.storage_adapter(media.disk)
    poster_path = poster_storage_path(media)

    case StorageWrapper.put(storage, poster_path, jpeg_data) do
      :ok ->
        poster_url = UrlGenerator.url_for_path(media, poster_path)

        updated_responsive =
          Map.put(media.responsive_images || %{}, "poster", %{
            "path" => poster_path,
            "url" => poster_url
          })

        {:ok, media} =
          Media.save_changes(media, [responsive_images: updated_responsive], write: false)

        media

      {:error, _} ->
        media
    end
  end

  defp poster_storage_path(media) do
    base_dir = Path.dirname(PathGenerator.relative_path(media, nil))
    Path.join(base_dir, "poster.jpg")
  end

  defp coerce_float(nil), do: 0.0
  defp coerce_float(v) when is_float(v), do: v
  defp coerce_float(v) when is_integer(v), do: v * 1.0

  defp coerce_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp coerce_float(_), do: 0.0

  # Blurhash needs the optional :image library; without it there is nothing
  # to generate (and no clause to compile that could never match).
  if Code.ensure_loaded?(Image) do
    defp maybe_generate_blurhash(media, file_path) do
      case PhxMediaLibrary.Blurhash.generate(file_path) do
        {:ok, hash} ->
          updated_responsive = Map.put(media.responsive_images || %{}, "blurhash", hash)

          {:ok, media} =
            Media.save_changes(media, [responsive_images: updated_responsive], write: false)

          media

        {:error, _} ->
          # Blurhash generation failed (e.g. unsupported format). Don't
          # fail the upload, just skip the placeholder.
          media
      end
    end
  else
    defp maybe_generate_blurhash(media, _file_path), do: media
  end

  # PhxMediaLibrary.Transfer moves media by adding its original again in
  # place of the record (`replacing:`), which keeps its id.
  defp record_id(opts) do
    case opts[:replacing] do
      %Media{id: id} -> id
      nil -> PhxMediaLibrary.UUIDv7.generate()
    end
  end

  # Every file is already stored (original and derivatives); don't leave
  # them behind if the write fails, but never remove a file the replaced
  # record still owns.
  defp insert_or_remove_files(%Media{} = derived, replacing) do
    attrs = derived |> Map.from_struct() |> Map.take(Media.__schema__(:fields))

    result =
      case replacing do
        nil -> %Media{id: derived.id} |> Media.changeset(attrs) |> Config.repo().insert()
        %Media{} -> replacing |> Media.changeset(attrs) |> Config.repo().update()
      end

    with {:error, _} <- result do
      storage = Config.storage_adapter(derived.disk)
      kept = if replacing, do: Media.owned_paths(replacing), else: []
      Enum.each(Media.owned_paths(derived) -- kept, &StorageWrapper.delete(storage, &1))
      result
    end
  end

  # Dispatch background work (conversions, and placeholders, which the job
  # makes after them), then (for WebP keep_original: false) drop the source.
  #
  # The job reads the original, so when it is about to be dropped it runs
  # synchronously first; if a conversion fails, the original is kept so it
  # can be retried. Otherwise the job stays async and the original is
  # retained.
  defp process_conversions_and_finalize_webp(adder, media, collection_name) do
    conversions = Model.conversions(adder.model, collection_name)

    background? = conversions != [] or placeholder?(adder, media, collection_name)

    drop_original? =
      Pipeline.webp_served?(media) and
        not Keyword.get(Model.webp_settings(adder.model, collection_name), :keep_original, true)

    cond do
      drop_original? and background? ->
        if Config.async_processor().process_sync(media, conversions) == :ok,
          do: drop_original(media, adder),
          else: media

      drop_original? ->
        drop_original(media, adder)

      background? ->
        Config.async_processor().process_async(media, conversions)
        media

      true ->
        media
    end
  end

  defp placeholder?(adder, media, collection_name),
    do: image?(media.mime_type) and Model.placeholder(adder.model, collection_name) != false

  # file_name keeps naming the (now absent) source; URL helpers serve the WebP.
  defp drop_original(media, adder) do
    Pipeline.drop_original(media, model: adder.model)
    media
  end

  defp generate_uuid, do: PhxMediaLibrary.UUIDv7.generate()

  defp source_type({:url, _, _}), do: :url
  defp source_type({:url, _}), do: :url
  defp source_type(%{__struct__: Plug.Upload}), do: :upload
  defp source_type(%{path: _, filename: _}), do: :upload_entry
  defp source_type(path) when is_binary(path), do: :path
  defp source_type({kind, _data, _filename}) when kind in [:binary, :base64, :stream], do: kind
  defp source_type(_), do: :unknown
end
