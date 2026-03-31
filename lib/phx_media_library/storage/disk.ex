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
    base_url = Keyword.get(opts, :base_url, "/uploads")
    signed = Keyword.get(opts, :signed, false)
    download = Keyword.get(opts, :download, false)

    cond do
      signed ->
        generate_signed_url(path, opts, download)

      download ->
        generate_download_url(path, opts)

      true ->
        Path.join(base_url, path)
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

    {token, expires_at} =
      PhxMediaLibrary.SignedUrl.sign(path,
        secret_key_base: secret,
        expires_in: expires_in
      )

    query_params = %{"sign" => token, "exp" => to_string(expires_at)}

    query_params =
      if include_disposition, do: Map.put(query_params, "dl", "1"), else: query_params

    "#{download_base}/#{path}?#{URI.encode_query(query_params)}"
  end

  # Generates a plain (unsigned) download URL routed through
  # PhxMediaLibrary.Plug.MediaDownload. No signing — use your Phoenix auth
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

    "#{download_base}/#{path}?dl=1"
  end
end
