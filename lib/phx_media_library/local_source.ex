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
    case PathGenerator.full_path(media, conversion) do
      path when is_binary(path) -> fun.(path)
      nil -> with_fetched_copy(media, conversion, fun)
    end
  end

  defp with_fetched_copy(media, conversion, fun) do
    storage = Config.storage_adapter(media.disk)
    relative = PathGenerator.relative_path(media, conversion)

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
