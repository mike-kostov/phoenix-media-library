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
  - `:download_base_url` - Base URL where `PhxMediaLibrary.Plug.MediaDownload`
    is mounted. Required when using `download: true` or `signed: true` URL
    generation. Example: `"/media"`.
  - `:secret_key_base` - HMAC secret for signing local URLs. Required when
    using `signed: true`. Should be at least 32 bytes of random data.

  ## Signed and Download URLs

  When `PhxMediaLibrary.Plug.MediaDownload` is mounted in the router and
  `download_base_url` + `secret_key_base` are configured, local URLs can be
  signed and/or served with a `Content-Disposition: attachment` header:

      # router.ex
      forward "/media", PhxMediaLibrary.Plug.MediaDownload, disk: :local

      # config.exs
      config :phx_media_library,
        disks: [
          local: [
            adapter: PhxMediaLibrary.Storage.Disk,
            root: "priv/static/uploads",
            base_url: "/uploads",
            download_base_url: "/media",
            secret_key_base: "long-random-secret-at-least-32-bytes"
          ]
        ]

  Then generate URLs via `PhxMediaLibrary.download_url/3` or
  `PhxMediaLibrary.signed_url/3`.

  """

  @behaviour PhxMediaLibrary.Storage

  alias PhxMediaLibrary.Storage

  @impl true
  def put(path, content, opts) do
    with {:ok, full_path} <- inside_root(path, opts) do
      # Ensure directory exists
      full_path |> Path.dirname() |> File.mkdir_p!()
      write(full_path, content)
    end
  end

  defp write(full_path, {:stream, stream}) do
    File.open!(full_path, [:write, :binary], fn file ->
      Enum.each(stream, &IO.binwrite(file, &1))
    end)

    :ok
  end

  defp write(full_path, binary) when is_binary(binary), do: File.write(full_path, binary)

  @impl true
  def get(path, opts \\ []) do
    with {:ok, full_path} <- inside_root(path, opts) do
      File.read(full_path)
    end
  end

  @impl true
  def delete(path, opts \\ []) do
    with {:ok, full_path} <- inside_root(path, opts) do
      case File.rm(full_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  @impl true
  def stat(path, header_bytes, opts) do
    with {:ok, full_path} <- inside_root(path, opts),
         {:ok, %File.Stat{size: size}} <- File.stat(full_path),
         {:ok, file} <- File.open(full_path, [:read, :binary]) do
      header =
        case IO.binread(file, header_bytes) do
          data when is_binary(data) -> data
          _eof -> <<>>
        end

      File.close(file)
      {:ok, %{size: size, header: header}}
    end
  end

  @impl true
  def exists?(path, opts \\ []) do
    case inside_root(path, opts) do
      {:ok, full_path} -> File.exists?(full_path)
      {:error, _} -> false
    end
  end

  @impl true
  def url(path, opts) do
    base_url = Keyword.get(opts, :base_url, "/uploads")
    signed = Keyword.get(opts, :signed, false)
    download = Keyword.get(opts, :download, false)

    cond do
      signed ->
        generate_signed_url(path, opts, download)

      download ->
        generate_download_url(path, opts)

      true ->
        Path.join(base_url, Storage.url_path(path))
    end
  end

  @impl true
  def path(path, opts) do
    root = Keyword.fetch!(opts, :root)
    Path.join(root, path)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Resolve `path` under the disk root, refusing anything that escapes it
  # (e.g. a `..` segment from an unsanitized filename).
  defp inside_root(path, opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()
    full_path = root |> Path.join(path) |> Path.expand()

    if String.starts_with?(full_path, root <> "/") do
      {:ok, full_path}
    else
      {:error, :path_outside_root}
    end
  end

  # Generates an HMAC-signed URL routed through PhxMediaLibrary.Plug.MediaDownload.
  # The token covers the path + expiry timestamp to prevent tampering with either.
  defp generate_signed_url(path, opts, include_disposition) do
    secret =
      Keyword.get(opts, :secret_key_base) ||
        Application.get_env(:phx_media_library, :secret_key_base) ||
        raise """
        PhxMediaLibrary: signed: true requires a secret_key_base to be configured.

        Add it to the disk config:

            config :phx_media_library,
              disks: [
                local: [
                  adapter: PhxMediaLibrary.Storage.Disk,
                  root: "priv/static/uploads",
                  base_url: "/uploads",
                  download_base_url: "/media",
                  secret_key_base: "long-random-secret-at-least-32-bytes"
                ]
              ]

        Or as a top-level application env:

            config :phx_media_library, secret_key_base: "..."
        """

    download_base =
      Keyword.get(opts, :download_base_url) ||
        Application.get_env(:phx_media_library, :download_base_url) ||
        raise """
        PhxMediaLibrary: signed: true requires download_base_url to be configured.

        Add it to the disk config (must match where Plug.MediaDownload is mounted):

            config :phx_media_library,
              disks: [local: [..., download_base_url: "/media"]]
        """

    expires_in = Keyword.get(opts, :expires_in, 3600)
    # A download carries its name (the uploaded one, see UrlGenerator),
    # covered by the signature.
    name = if include_disposition, do: Keyword.get(opts, :filename)

    {token, expires_at} =
      PhxMediaLibrary.SignedUrl.sign(path,
        secret_key_base: secret,
        expires_in: expires_in,
        name: name
      )

    query_params = %{"sign" => token, "exp" => to_string(expires_at)}

    query_params =
      if include_disposition, do: Map.put(query_params, "dl", "1"), else: query_params

    query_params = if name, do: Map.put(query_params, "name", name), else: query_params

    "#{download_base}/#{Storage.url_path(path)}?#{URI.encode_query(query_params)}"
  end

  # Generates a plain (unsigned) download URL routed through
  # PhxMediaLibrary.Plug.MediaDownload. No signing. Use your Phoenix auth
  # pipeline to restrict access.
  defp generate_download_url(path, opts) do
    download_base =
      Keyword.get(opts, :download_base_url) ||
        Application.get_env(:phx_media_library, :download_base_url) ||
        raise """
        PhxMediaLibrary: download: true requires download_base_url to be configured.

        Add it to the disk config (must match where Plug.MediaDownload is mounted):

            config :phx_media_library,
              disks: [local: [..., download_base_url: "/media"]]
        """

    "#{download_base}/#{Storage.url_path(path)}?dl=1"
  end
end
