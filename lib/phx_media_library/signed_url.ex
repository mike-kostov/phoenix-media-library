defmodule PhxMediaLibrary.SignedUrl do
  @moduledoc """
  HMAC-SHA256 signing and verification for time-limited local-disk URLs.

  URLs signed by this module are intended for use with
  `PhxMediaLibrary.Plug.MediaDownload`, which calls `verify/4` before serving
  a file. This provides a lightweight security layer for local-disk storage
  that mirrors the presigned-URL pattern already available for S3.

  ## How It Works

  A signed URL looks like:

      /media/images/1/uuid/photo.jpg?sign=<token>&exp=<unix_timestamp>

  The `token` is:

      Base64URL( HMAC-SHA256( secret_key_base, "<path>|<expires_at>" ) )

  The token and `expires_at` are both validated on each request:

  1. The expiry timestamp is checked against `System.system_time(:second)`.
  2. A new token is recomputed from the path + expiry using the same secret
     and compared in **constant time** to prevent timing-based token forgery.

  ## Configuration

  Add `secret_key_base` and `download_base_url` to the disk config (or as
  top-level `:phx_media_library` application env):

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

  In the Phoenix router, mount the plug at the same base path:

      forward "/media", PhxMediaLibrary.Plug.MediaDownload, disk: :local

  Generate a signed URL via `PhxMediaLibrary.signed_url/3`:

      PhxMediaLibrary.signed_url(media)
      #=> "/media/images/1/uuid/photo.jpg?sign=abc...&exp=1712345600"

      PhxMediaLibrary.signed_url(media, nil, expires_in: 300)

  """

  @hash_algo :sha256

  @doc """
  Sign a storage path and return `{token, expires_at}`.

  `expires_at` is an absolute Unix timestamp (seconds). The caller is
  responsible for embedding both values in the URL query string.

  ## Options

  - `:secret_key_base` — (required) the signing secret.
  - `:expires_in` — seconds from now until the URL expires (default: `3600`).

  ## Examples

      iex> {token, exp} = PhxMediaLibrary.SignedUrl.sign("images/1/uuid/photo.jpg",
      ...>   secret_key_base: "my-secret",
      ...>   expires_in: 600
      ...> )
      iex> is_binary(token) and is_integer(exp)
      true

  """
  @spec sign(String.t(), keyword()) :: {String.t(), integer()}
  def sign(path, opts) do
    secret = Keyword.fetch!(opts, :secret_key_base)
    expires_in = Keyword.get(opts, :expires_in, 3600)
    expires_at = System.system_time(:second) + expires_in

    token = compute_token(secret, path, expires_at)
    {token, expires_at}
  end

  @doc """
  Verify a signed token for the given path.

  Returns `:ok` if the token is valid and has not expired, or one of:

  - `{:error, :expired}` — the URL's expiry timestamp is in the past.
  - `{:error, :invalid_token}` — the HMAC does not match (wrong secret,
    tampered path, or tampered expiry).

  ## Arguments

  - `path` — the storage-relative path extracted from the request (must match
    exactly what was signed, without leading slash).
  - `token` — the `sign` query param from the URL.
  - `expires_at` — the `exp` query param, as an integer Unix timestamp.
  - `secret` — the signing secret (same value used in `sign/2`).

  ## Examples

      iex> {token, exp} = PhxMediaLibrary.SignedUrl.sign("images/1/uuid/photo.jpg",
      ...>   secret_key_base: "my-secret"
      ...> )
      iex> PhxMediaLibrary.SignedUrl.verify("images/1/uuid/photo.jpg", token, exp, "my-secret")
      :ok

      iex> PhxMediaLibrary.SignedUrl.verify("images/1/uuid/photo.jpg", "bad-token", exp, "my-secret")
      {:error, :invalid_token}

  """
  @spec verify(String.t(), String.t(), integer(), String.t()) ::
          :ok | {:error, :expired | :invalid_token}
  def verify(path, token, expires_at, secret) do
    cond do
      System.system_time(:second) > expires_at ->
        {:error, :expired}

      not constant_time_equal(token, compute_token(secret, path, expires_at)) ->
        {:error, :invalid_token}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_token(secret, path, expires_at) do
    :crypto.mac(:hmac, @hash_algo, secret, "#{path}|#{expires_at}")
    |> Base.url_encode64(padding: false)
  end

  # Constant-time binary comparison to mitigate timing-based token oracle
  # attacks. We XOR every byte-pair and OR all differences; only returns true
  # when every XOR is zero (i.e. both binaries are identical).
  #
  # We guard on equal length first because different lengths trivially leak
  # information regardless of comparison strategy — length is not secret.
  defp constant_time_equal(a, b)
       when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    Enum.reduce(Enum.zip(a_bytes, b_bytes), 0, fn {x, y}, acc ->
      :erlang.bor(acc, :erlang.bxor(x, y))
    end) == 0
  end

  defp constant_time_equal(_a, _b), do: false
end
