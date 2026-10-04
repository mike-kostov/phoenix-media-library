defmodule PhxMediaLibrary.UrlGenerator do
  @moduledoc """
  Generates URLs for media files.

  ## Options

  All URL-generating functions accept the following options in addition to
  any adapter-specific options:

  - `:cache_bust` — `boolean` — when `true` and the media item has a stored
    checksum, appends a `?vsn={checksum[0..7]}` query parameter so that CDN
    edges serve a fresh object whenever the file changes. Defaults to `false`.

  - `:signed` — `boolean` — when `true`, generates a signed/expiring URL.
    For S3 this is an AWS Signature V4 presigned GET URL. For local disk
    this is an HMAC-signed URL that can be verified by
    `PhxMediaLibrary.Plug.MediaDownload`. Requires `:expires_in` (see below).
    Defaults to `false`.

  - `:expires_in` — `integer` — expiry window in seconds for signed URLs
    (default: `3600`). Has no effect unless `:signed` is `true`.

  - `:download` — `boolean` — when `true`, generates a URL suitable for
    file downloads. For S3, this attaches a `Content-Disposition: attachment`
    response header to the presigned URL. For local disk, the URL routes
    through `PhxMediaLibrary.Plug.MediaDownload` which sets the header.
    Implies `:signed` for S3 (a presigned URL is required). Defaults to
    `false`.

  - `:filename` — `String.t()` — override the filename used in the
    `Content-Disposition` header when `:download` is `true`. Defaults to the
    uploaded file's name (`metadata["original_file_name"]`), else
    `file_name`. Unsigned disk download URLs always use the stored name.

  ## CDN Cache-Busting

  When assets are served through a CDN you typically want far-future
  `Cache-Control` headers and a content-fingerprint in the URL so the CDN
  picks up the new asset when you replace a file. The fingerprint is a
  `vsn` parameter, which `Plug.Static` answers with a one-year
  `Cache-Control` by default (`cache_control_for_vsn_requests`); on S3, set
  the disk's `cache_control:` option.

  The fingerprint comes from the original's checksum, so files regenerated
  in place (`mix phx_media_library.doctor --rebuild`) keep their URL: purge
  your CDN after a rebuild.

      # Regular URL
      PhxMediaLibrary.url(media)
      #=> "/uploads/images/42/abc/photo.jpg"

      # CDN URL with cache-busting checksum
      PhxMediaLibrary.cdn_url(media)
      #=> "/uploads/images/42/abc/photo.jpg?vsn=a1b2c3d4"

      # Explicit option form
      PhxMediaLibrary.url(media, nil, cache_bust: true)
      #=> "/uploads/images/42/abc/photo.jpg?vsn=a1b2c3d4"

  ## Signed / Expiring URLs

  For S3 (already supported by the adapter):

      PhxMediaLibrary.signed_url(media)
      #=> "https://bucket.s3.amazonaws.com/...?X-Amz-Signature=..."

      PhxMediaLibrary.signed_url(media, nil, expires_in: 300)

  For local disk storage (requires `PhxMediaLibrary.Plug.MediaDownload` to be
  mounted in the app's router):

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
            secret_key_base: "long-random-secret"
          ]
        ]

  ## Download Links

  For S3, this generates a presigned URL with `response-content-disposition`:

      PhxMediaLibrary.download_url(media)
      #=> "https://bucket.s3.amazonaws.com/...?response-content-disposition=attachment..."

  For local disk, the URL routes through `PhxMediaLibrary.Plug.MediaDownload`
  which serves the file with `Content-Disposition: attachment`.
  """

  alias PhxMediaLibrary.{Config, Media, PathGenerator, StorageWrapper}

  @doc """
  Generate a URL for a media item.

  ## Arguments

  - `media` — the `PhxMediaLibrary.Media` struct.
  - `conversion` — optional conversion name atom (e.g. `:thumb`). Pass
    `nil` (default) for the original file.
  - `opts` — keyword list of options (see module docs).
  """
  @spec url(Media.t(), atom() | nil, keyword()) :: String.t()
  def url(%Media{} = media, conversion \\ nil, opts \\ []) do
    do_url(media, conversion, opts)
  end

  @doc """
  A full URL, including scheme and host, for places that need one: the
  `og:image` meta tag, image sitemaps, emails, JSON APIs.

  `base` is your Phoenix endpoint (its `url/0` is used) or a URL string,
  e.g. a CDN host. URLs that are already absolute (S3, a CDN `base_url`)
  are returned unchanged. `opts` are those of `url/3`.

  ## Examples

      UrlGenerator.absolute_url(media, :preview, MyAppWeb.Endpoint)
      #=> "https://shop.example/uploads/products/42/…/preview.jpg"

      UrlGenerator.absolute_url(media, nil, "https://cdn.example")
      #=> "https://cdn.example/uploads/products/42/…/red-dress.jpg"

  """
  @spec absolute_url(Media.t(), atom() | nil, module() | String.t(), keyword()) :: String.t()
  def absolute_url(%Media{} = media, conversion, base, opts \\ []) do
    url = do_url(media, conversion, opts)

    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> url
      %URI{host: host} when is_binary(host) -> "https:" <> url
      _relative -> base |> base_url() |> URI.merge(url) |> URI.to_string()
    end
  end

  defp base_url(base) when is_binary(base), do: base
  defp base_url(endpoint) when is_atom(endpoint), do: endpoint.url()

  defp do_url(%Media{} = media, conversion, opts) do
    opts = with_download_name(opts, media)
    {cache_bust, opts} = Keyword.pop(opts, :cache_bust, false)
    {width, adapter_opts} = Keyword.pop(opts, :width)

    storage = Config.storage_adapter(media.disk)
    relative_path = variant_path(media, conversion, width) || served_path(media, conversion)

    base_url = StorageWrapper.url(storage, relative_path, adapter_opts)

    maybe_add_cache_bust(base_url, media.checksum, cache_bust)
  end

  # Downloads are named after the uploaded file, not the stored one.
  defp with_download_name(opts, media) do
    if Keyword.get(opts, :download, false) do
      Keyword.put_new_lazy(opts, :filename, fn ->
        (media.metadata || %{})["original_file_name"] || media.file_name
      end)
    else
      opts
    end
  end

  # When a WebP derivative was generated for the original (keep_original: true),
  # serve it instead of the source file. Named conversions resolve normally.
  defp served_path(%Media{custom_properties: %{"webp" => webp}}, nil) when is_binary(webp),
    do: webp

  defp served_path(media, conversion), do: PathGenerator.relative_path(media, conversion)

  # `width:` picks the smallest responsive variant at least that wide, else the
  # widest one. `nil` when the media has no variants for the conversion, so the
  # caller falls back to the regular served path.
  defp variant_path(_media, _conversion, nil), do: nil

  defp variant_path(%Media{} = media, conversion, width) when is_integer(width) and width > 0 do
    sorted = Media.responsive_variants(media, conversion)

    case Enum.find(sorted, &(&1["width"] >= width)) || List.last(sorted) do
      %{"path" => path} when is_binary(path) -> path
      _ -> nil
    end
  end

  @doc """
  Generate a URL for a specific path (used for responsive images / poster
  frames that are stored at an explicit path rather than a derived one).

  ## Options

  Accepts `:cache_bust` with an explicit `checksum` string, or any
  adapter-specific options.
  """
  @spec url_for_path(Media.t(), String.t(), keyword()) :: String.t()
  def url_for_path(%Media{disk: disk}, path, opts \\ []) do
    {cache_bust_checksum, adapter_opts} = Keyword.pop(opts, :cache_bust_checksum)

    storage = Config.storage_adapter(disk)
    base_url = StorageWrapper.url(storage, path, adapter_opts)

    if cache_bust_checksum do
      maybe_add_cache_bust(base_url, cache_bust_checksum, true)
    else
      base_url
    end
  end

  @doc """
  Generate a CDN-friendly URL with cache-busting via a content-fingerprint
  query parameter.

  Equivalent to `url(media, conversion, cache_bust: true)`.

  When the media item has no stored checksum (e.g. legacy records), returns
  the plain URL without any query parameter.

  ## Examples

      iex> PhxMediaLibrary.UrlGenerator.cdn_url(media)
      "/uploads/images/1/uuid/photo.jpg?vsn=a1b2c3d4"

      iex> PhxMediaLibrary.UrlGenerator.cdn_url(media, :thumb)
      "/uploads/images/1/uuid/photo_thumb.jpg?vsn=a1b2c3d4"

  """
  @spec cdn_url(Media.t(), atom() | nil) :: String.t()
  def cdn_url(%Media{} = media, conversion \\ nil) do
    url(media, conversion, cache_bust: true)
  end

  @doc """
  Generate a download URL for a media item.

  For **S3** storage this generates a presigned GET URL that instructs the
  browser (and S3) to serve the file with a `Content-Disposition: attachment`
  header so the browser downloads rather than renders the file.

  For **local disk** storage the URL routes through
  `PhxMediaLibrary.Plug.MediaDownload` which sets the `Content-Disposition`
  header when serving the file. The plug must be mounted in the app's router.

  Equivalent to `url(media, conversion, download: true)`.

  ## Options

  Accepts all options supported by `url/3`. Additionally:

  - `:filename` — override the filename in the `Content-Disposition` header.
    Defaults to the uploaded file's name, else `media.file_name`.
  - `:expires_in` — expiry for the presigned URL in seconds (S3 only).
    Defaults to `3600`.

  ## Examples

      iex> PhxMediaLibrary.UrlGenerator.download_url(media)
      "https://bucket.s3.../file.zip?...\&response-content-disposition=attachment..."

      # Local disk (requires Plug.MediaDownload mounted at "/media")
      iex> PhxMediaLibrary.UrlGenerator.download_url(media)
      "/media/images/1/uuid/photo.jpg"

  """
  @spec download_url(Media.t(), atom() | nil, keyword()) :: String.t()
  def download_url(%Media{} = media, conversion \\ nil, opts \\ []) do
    url(media, conversion, Keyword.put(opts, :download, true))
  end

  @doc """
  Generate a signed, time-limited URL for a media item.

  For **S3** storage this is an AWS Signature V4 presigned GET URL valid for
  `:expires_in` seconds (default: 3600).

  For **local disk** storage this generates an HMAC-signed URL that is
  verified by `PhxMediaLibrary.Plug.MediaDownload`. A `secret_key_base`
  must be present in the disk configuration and the plug must be mounted.

  Equivalent to `url(media, conversion, signed: true)`.

  ## Options

  - `:expires_in` — expiry window in seconds (default: `3600`).
  - `:download` — also attach a `Content-Disposition: attachment` header
    (see `download_url/3`).

  ## Examples

      iex> PhxMediaLibrary.UrlGenerator.signed_url(media)
      "https://bucket.s3.../file.jpg?X-Amz-Signature=..."

      iex> PhxMediaLibrary.UrlGenerator.signed_url(media, nil, expires_in: 300)

  """
  @spec signed_url(Media.t(), atom() | nil, keyword()) :: String.t()
  def signed_url(%Media{} = media, conversion \\ nil, opts \\ []) do
    url(media, conversion, Keyword.put(opts, :signed, true))
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Appends vsn={first-8-chars-of-checksum} when cache_bust is true and the
  # media item has a non-nil checksum.
  defp maybe_add_cache_bust(url, checksum, true) when is_binary(checksum) do
    # `vsn` is what Plug.Static's cache_control_for_vsn_requests looks for.
    # Signed URLs already carry a query string.
    suffix = binary_part(checksum, 0, min(8, byte_size(checksum)))
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    "#{url}#{separator}vsn=#{suffix}"
  end

  defp maybe_add_cache_bust(url, _checksum, _cache_bust), do: url
end
