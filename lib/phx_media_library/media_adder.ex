defmodule PhxMediaLibrary.MediaAdder do
  @moduledoc """
  Builder struct for adding media to a model.

  This module provides a fluent API for configuring media before
  it is persisted to storage and the database.

  You typically won't use this module directly - instead use the
  functions in `PhxMediaLibrary` which delegate here.
  """

  alias PhxMediaLibrary.{Media, Config, Storage, PathGenerator, Conversions, Collection}

  defstruct [
    :model,
    :source,
    :filename,
    :custom_properties,
    :responsive_images,
    :disk
  ]

  @type source :: Path.t() | {:url, String.t()} | map()

  @type t :: %__MODULE__{
          model: Ecto.Schema.t(),
          source: source(),
          filename: String.t() | nil,
          custom_properties: map(),
          responsive_images: boolean(),
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
      responsive_images: false
    }
  end

  @doc """
  Set a custom filename.
  """
  @spec using_filename(t(), String.t()) :: t()
  def using_filename(%__MODULE__{} = adder, filename) do
    %{adder | filename: filename}
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
    %{adder | responsive_images: true}
  end

  @doc """
  Finalize and persist the media.
  """
  @spec to_collection(t(), atom(), keyword()) :: {:ok, Media.t()} | {:error, term()}
  def to_collection(%__MODULE__{} = adder, collection_name, opts \\ []) do
    with {:ok, file_info} <- resolve_source(adder),
         {:ok, validated} <- validate_collection(adder, collection_name, file_info),
         {:ok, media} <- store_and_persist(validated, collection_name, file_info, opts) do
      # Trigger async conversion processing
      maybe_process_conversions(adder.model, media, collection_name)
      {:ok, media}
    end
  end

  # Private functions

  defp resolve_source(%__MODULE__{source: source, filename: custom_filename}) do
    case source do
      {:url, url} ->
        download_from_url(url, custom_filename)

      path when is_binary(path) ->
        resolve_file_path(path, custom_filename)

      %{path: path, filename: original_filename} ->
        # Phoenix.LiveView.UploadEntry or similar
        resolve_file_path(path, custom_filename || original_filename)

      %Plug.Upload{path: path, filename: original_filename} ->
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

      %Collection{accepts: accepts} = config when is_list(accepts) and accepts != [] ->
        if file_info.mime_type in accepts do
          {:ok, config}
        else
          {:error, {:invalid_mime_type, file_info.mime_type, accepts}}
        end

      config ->
        {:ok, config}
    end
  end

  defp store_and_persist(%__MODULE__{} = adder, collection_name, file_info, opts) do
    uuid = generate_uuid()
    disk = opts[:disk] || adder.disk || get_default_disk(adder.model, collection_name)
    storage = Config.storage_adapter(disk)

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
      order_column: get_next_order(adder.model, collection_name)
    }

    # Determine storage path
    storage_path = PathGenerator.for_new_media(attrs)

    # Store the file
    with {:ok, _} <- storage.put(storage_path, File.read!(file_info.path)),
         {:ok, media} <- insert_media(attrs) do
      # Handle single file collections
      maybe_cleanup_collection(adder.model, collection_name, media)

      # Cleanup temp file if needed
      if file_info.temp, do: File.rm(file_info.path)

      {:ok, media}
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
    model.__struct__
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>("s")
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
        model
        |> Media.for_model(collection_name)
        |> Enum.drop(max)
        |> Enum.each(&Media.delete/1)

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
end
