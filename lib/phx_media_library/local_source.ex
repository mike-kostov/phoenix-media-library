defmodule PhxMediaLibrary.LocalSource do
  @moduledoc """
  Gives image processing a local file to read, whatever the storage.

  Image processors (libvips) read from the filesystem. Local disks expose a
  path directly; remote storage such as S3 (and the in-memory adapter) has
  none, so the file is fetched into a temporary file for the duration of the
  callback and deleted afterwards.

      PhxMediaLibrary.LocalSource.with_path(media, :thumb, fn path -> Image.open(path) end)
  """

  alias PhxMediaLibrary.{Config, Media, PathGenerator, StorageWrapper}

  @doc """
  Call `fun` with a local path to the media's original (`conversion` nil) or
  to a generated conversion, returning whatever `fun` returns.

  Returns `{:error, reason}` without calling `fun` when the file can't be
  fetched from storage.

  ## Examples

      PhxMediaLibrary.LocalSource.with_path(media, nil, fn path ->
        Image.open(path)
      end)

  """
  @spec with_path(Media.t(), atom() | String.t() | nil, (String.t() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_path(%Media{} = media, conversion, fun) when is_function(fun, 1) do
    with_stored_path(media, PathGenerator.relative_path(media, conversion), fun)
  end

  @doc """
  Like `with_path/3`, for any file the media stores, by its storage path
  (its WebP, a responsive variant, ...).

  ## Examples

      PhxMediaLibrary.LocalSource.with_stored_path(media, media.custom_properties["webp"], &File.stat/1)

  """
  @spec with_stored_path(Media.t(), String.t(), (String.t() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_stored_path(%Media{} = media, relative, fun) when is_function(fun, 1) do
    storage = Config.storage_adapter(media.disk)
    Code.ensure_loaded(storage.adapter)

    # Adapters without local files (S3) may still define path/2, as nil.
    local =
      if function_exported?(storage.adapter, :path, 2),
        do: storage.adapter.path(relative, storage.config)

    if is_binary(local), do: fun.(local), else: with_fetched_copy(storage, relative, fun)
  end

  defp with_fetched_copy(storage, relative, fun) do
    with {:ok, content} <- StorageWrapper.get(storage, relative) do
      temp_path =
        Path.join(
          System.tmp_dir!(),
          "phx_media_source_#{:erlang.unique_integer([:positive])}#{Path.extname(relative)}"
        )

      File.write!(temp_path, content)

      try do
        fun.(temp_path)
      after
        File.rm(temp_path)
      end
    end
  end
end
