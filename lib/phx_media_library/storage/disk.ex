defmodule PhxMediaLibrary.Storage.Disk do
  @moduledoc """
  Local filesystem storage adapter.

  ## Configuration

      config :phx_media_library,
        disks: [
          local: [
            adapter: PhxMediaLibrary.Storage.Disk,
            root: "priv/static/uploads",
            base_url: "/uploads"
          ]
        ]

  ## Options

  - `:root` - Root directory for file storage (required)
  - `:base_url` - Base URL for generating public URLs (required)

  """

  @behaviour PhxMediaLibrary.Storage

  @impl true
  def put(path, content, opts) do
    root = Keyword.fetch!(opts, :root)
    full_path = Path.join(root, path)

    # Ensure directory exists
    full_path |> Path.dirname() |> File.mkdir_p!()

    case content do
      {:stream, stream} ->
        File.open!(full_path, [:write, :binary], fn file ->
          Enum.each(stream, &IO.binwrite(file, &1))
        end)

        :ok

      binary when is_binary(binary) ->
        File.write(full_path, binary)
    end
  end

  @impl true
  def get(path, opts \\ []) do
    root = Keyword.fetch!(opts, :root)
    full_path = Path.join(root, path)

    File.read(full_path)
  end

  @impl true
  def delete(path, opts \\ []) do
    root = Keyword.fetch!(opts, :root)
    full_path = Path.join(root, path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @impl true
  def exists?(path, opts \\ []) do
    root = Keyword.fetch!(opts, :root)
    full_path = Path.join(root, path)

    File.exists?(full_path)
  end

  @impl true
  def url(path, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    Path.join(base_url, path)
  end

  @impl true
  def path(path, opts) do
    root = Keyword.fetch!(opts, :root)
    Path.join(root, path)
  end
end
