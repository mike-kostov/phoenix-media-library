if Code.ensure_loaded?(Plug.Conn) do
  defmodule PhxMediaLibrary.Plug.MediaDownload do
    @moduledoc """
    A Plug that serves local-disk media files with optional `Content-Disposition`
    and HMAC-signed URL verification.

    ## Quick Start

    Mount the plug in your Phoenix router at the same path you configured as
    `download_base_url` in the disk config:

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

    ## Generating Download / Signed URLs

    Use the top-level helpers in `PhxMediaLibrary`:

        # Content-Disposition download link (no signing required for public media)
        href = PhxMediaLibrary.download_url(media)

        # HMAC-signed URL (expires in 1 hour by default)
        href = PhxMediaLibrary.signed_url(media)

        # Signed *and* downloadable
        href = PhxMediaLibrary.signed_url(media, nil, download: true, expires_in: 300)

    ## URL Formats

    **Unsigned download** (Content-Disposition only):

        GET /media/images/1/uuid/photo.jpg?dl=1

    **Signed** (no Content-Disposition):

        GET /media/images/1/uuid/photo.jpg?sign=<token>&exp=<unix_ts>

    **Signed download**:

        GET /media/images/1/uuid/photo.jpg?sign=<token>&exp=<unix_ts>&dl=1

    When a `sign` parameter is present the plug **always** verifies the token
    before serving the file. If the token is missing but the URL was generated
    with `signed: true`, verification fails with `403 Forbidden`.

    ## Plug Options

    - `:disk` — (required) the disk name atom (e.g. `:local`) to look up in
      the PhxMediaLibrary disk config. The disk must use
      `PhxMediaLibrary.Storage.Disk` as its adapter.

    - `:require_signed` — when `true`, every request must carry a valid
      `sign` + `exp` pair. Unsigned requests return `403 Forbidden`. Defaults
      to `false`, which allows unsigned requests (no token required for plain
      download links).

    ## Security Notes

    - Without `:require_signed`, any file under the configured `:root`
      directory can be downloaded via this plug. Use Phoenix's existing auth
      pipeline (`:require_authenticated_user`, etc.) to restrict access.
    - The HMAC secret (`secret_key_base`) should be at least 32 bytes of
      cryptographically random data.  Do **not** reuse your Phoenix
      `secret_key_base` for this purpose in production.
    """

    @behaviour Plug

    import Plug.Conn

    alias PhxMediaLibrary.{Config, SignedUrl}

    @impl Plug
    def init(opts) do
      disk = Keyword.fetch!(opts, :disk)
      require_signed = Keyword.get(opts, :require_signed, false)

      # Eagerly look up disk config to catch misconfiguration at startup.
      disk_config = Config.disk_config(disk)

      %{
        disk: disk,
        disk_config: disk_config,
        require_signed: require_signed
      }
    end

    @impl Plug
    def call(conn, %{disk_config: disk_config, require_signed: require_signed} = _opts) do
      # Reconstruct the relative path from the path segments that come *after*
      # the router's forward prefix.  Plug.Router strips the matched prefix and
      # stores what remains in `conn.path_info`.
      relative_path = Enum.join(conn.path_info, "/")

      query = conn.query_string |> URI.decode_query()

      sign_token = Map.get(query, "sign")
      exp_str = Map.get(query, "exp")
      download? = Map.get(query, "dl") == "1"

      with :ok <- check_signature(sign_token, exp_str, relative_path, disk_config, require_signed),
           {:ok, content, filename} <- read_file(relative_path, disk_config) do
        conn
        |> put_content_type(filename)
        |> maybe_add_content_disposition(filename, download?)
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, content)
        |> halt()
      else
        {:error, :forbidden} ->
          conn
          |> send_resp(403, "Forbidden")
          |> halt()

        {:error, :not_found} ->
          conn
          |> send_resp(404, "Not Found")
          |> halt()

        {:error, _reason} ->
          conn
          |> send_resp(500, "Internal Server Error")
          |> halt()
      end
    end

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    # No signing token in URL → allowed only when :require_signed is false.
    defp check_signature(nil, _exp, _path, _config, false), do: :ok

    defp check_signature(nil, _exp, _path, _config, true), do: {:error, :forbidden}

    # Signing token present → always verify it.
    defp check_signature(token, exp_str, path, disk_config, _require_signed)
         when is_binary(token) and is_binary(exp_str) do
      secret =
        Keyword.get(disk_config, :secret_key_base) ||
          Application.get_env(:phx_media_library, :secret_key_base)

      if is_nil(secret) do
        {:error, :forbidden}
      else
        case Integer.parse(exp_str) do
          {expires_at, ""} ->
            case SignedUrl.verify(path, token, expires_at, secret) do
              :ok -> :ok
              {:error, _reason} -> {:error, :forbidden}
            end

          _invalid ->
            {:error, :forbidden}
        end
      end
    end

    defp check_signature(_token, _exp, _path, _config, _require_signed) do
      {:error, :forbidden}
    end

    defp read_file(relative_path, disk_config) do
      root = Keyword.get(disk_config, :root, "priv/static/uploads")
      full_path = Path.join(root, relative_path)

      # Prevent path traversal: the resolved path must remain inside root.
      real_root = Path.expand(root)
      real_full = Path.expand(full_path)

      cond do
        not String.starts_with?(real_full, real_root <> "/") and real_full != real_root ->
          {:error, :forbidden}

        not File.exists?(real_full) ->
          {:error, :not_found}

        true ->
          case File.read(real_full) do
            {:ok, content} -> {:ok, content, Path.basename(relative_path)}
            {:error, _reason} -> {:error, :not_found}
          end
      end
    end

    defp put_content_type(conn, filename) do
      mime_type = MIME.from_path(filename)
      put_resp_content_type(conn, mime_type)
    end

    defp maybe_add_content_disposition(conn, filename, true) do
      safe_name = String.replace(filename, ~s("), ~s(\\"))
      put_resp_header(conn, "content-disposition", ~s(attachment; filename="#{safe_name}"))
    end

    defp maybe_add_content_disposition(conn, _filename, false), do: conn
  end
end
