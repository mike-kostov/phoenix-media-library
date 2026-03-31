defmodule PhxMediaLibrary.UrlGenerator do
  @moduledoc """
  Generates URLs for media files.

  ## Options

  All URL-generating functions accept the following options in addition to
  any adapter-specific options:

  - `:cache_bust` — `boolean` — when `true` and the media item has a stored
    checksum, appends a `?v={checksum[0..7]}` query parameter so that CDN
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
    media item's `file_name`.

  ## CDN Cache-Busting

  When assets are served through a CDN you typically want far-future
  `Cache-Control` headers and a content-fingerprint in the URL so the CDN
  picks up the new asset when you replace a file.

      # Regular URL
      PhxMediaLibrary.url(media)
      #=> "/uploads/images/42/abc/photo.jpg"

      # CDN URL with cache-busting checksum
      PhxMediaLibrary.cdn_url(media)
      #=> "/uploads/images/42/abc/photo.jpg?v=a1b2c3d4"

      # Explicit option form
      PhxMediaLibrary.url(media, nil, cache_bust: true)
      #=> "/uploads/images/42/abc/photo.jpg?v=a1b2c3d4"

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
    {cache_bust, adapter_opts} = Keyword.pop(opts, :cache_bust, false)

    storage = Config.storage_adapter(media.disk)
    relative_path = PathGenerator.relative_path(media, conversion)

    base_url = StorageWrapper.url(storage, relative_path, adapter_opts)

    maybe_add_cache_bust(base_url, media.checksum, cache_bust)
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
      "/uploads/images/1/uuid/photo.jpg?v=a1b2c3d4"

      iex> PhxMediaLibrary.UrlGenerator.cdn_url(media, :thumb)
      "/uploads/images/1/uuid/photo_thumb.jpg?v=a1b2c3d4"

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
    Defaults to `media.file_name`.
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

  # Appends ?v={first-8-chars-of-checksum} when cache_bust is true and the
  # media item has a non-nil checksum.
  defp maybe_add_cache_bust(url, checksum, true) when is_binary(checksum) do
    suffix = binary_part(checksum, 0, min(8, byte_size(checksum)))
    "#{url}?v=#{suffix}"
  end

  defp maybe_add_cache_bust(url, _checksum, _cache_bust), do: url
end
