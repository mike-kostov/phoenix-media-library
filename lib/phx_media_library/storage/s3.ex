if Code.ensure_loaded?(ExAws.S3) do
  defmodule PhxMediaLibrary.Storage.S3 do
    @moduledoc """
    Storage adapter for Amazon S3 and S3-compatible services (Cloudflare R2,
    DigitalOcean Spaces, Backblaze B2, MinIO and others).

    Requires `ex_aws` and `ex_aws_s3` dependencies. This module is only
    compiled when `:ex_aws_s3` is available. If it is not installed,
    the module simply does not exist. Configuring an S3 disk without the
    dependency will produce a clear "module is not available" error.

    ## Configuration

        config :phx_media_library,
          disks: [
            s3: [
              adapter: PhxMediaLibrary.Storage.S3,
              bucket: "my-bucket",
              region: "us-east-1",
              # Optional: Override ExAws config
              access_key_id: "...",
              secret_access_key: "..."
            ],
            r2: [
              adapter: PhxMediaLibrary.Storage.S3,
              provider: :r2,
              account_id: "...",
              bucket: "media",
              base_url: "https://media.example.com"
            ]
          ]

    ## Providers

    `:provider` picks default values for the other options; any option set
    on the disk wins over its provider's default.

    | Provider | Defaults |
    |---|---|
    | `:aws` (default) | AWS endpoint, `direct_upload: :post` |
    | `:r2` | endpoint `https://<account_id>.r2.cloudflarestorage.com`, `region: "auto"`, `direct_upload: :put`; public URLs need `:base_url` |
    | `:generic` | `direct_upload: :put`; set `:endpoint` |

    Every provider uses path-style addressing and sends no ACL by default.
    Any other S3-compatible service works as `:generic` with its settings.

    ## Options

    - `:bucket` - S3 bucket name (required)
    - `:provider` - `:aws`, `:r2` or `:generic` (default: `:aws`)
    - `:region` - AWS region (default: from ExAws config; `"auto"` on R2)
    - `:account_id` - Cloudflare account ID, for `provider: :r2`
    - `:endpoint` - API URL of an S3-compatible service, e.g.
      `"https://s3.example.com"` (default: AWS, or R2's from `:account_id`)
    - `:addressing` - `:path` (`<endpoint>/<bucket>/<key>`, the default) or
      `:virtual_host` (`<bucket>.<endpoint host>/<key>`)
    - `:base_url` - Custom base URL for public URLs (a CDN or custom
      domain). Without it, public URLs follow the endpoint; R2 serves
      public files only from a custom domain or r2.dev URL, so `:r2` disks
      need it
    - `:direct_upload` - how browsers upload directly (see
      `PhxMediaLibrary.presigned_upload/3`): `:post`, a form whose signed
      policy limits the size, or `:put`, for providers without POST
      uploads such as R2
    - `:acl` - ACL sent with uploads, e.g. `"public-read"` (default: none,
      so the bucket's settings apply)
    - `:cache_control` - `Cache-Control` header stored with every upload,
      e.g. `"public, max-age=31536000, immutable"` for files served through
      a CDN with `cache_bust: true` URLs (default: none)

    """

    @behaviour PhxMediaLibrary.Storage

    # Minimum multipart part size imposed by S3 (and LocalStack).
    # Every part except the last must be >= 5 MiB; we target exactly this
    # so that even the last part of a very large file stays on the safe side.
    @multipart_part_size 5 * 1024 * 1024

    # Provider presets (ADR-025): default values only, never code paths.
    @presets %{
      aws: [direct_upload: :post, addressing: :path],
      r2: [region: "auto", direct_upload: :put, addressing: :path],
      generic: [direct_upload: :put, addressing: :path]
    }

    @doc """
    The disk's options with its provider's defaults filled in.

    Options set on the disk win; `nil` values are ignored. Raises
    `ArgumentError` for an unknown provider, or an `:r2` disk without
    `:account_id` or `:endpoint`.

    ## Examples

        iex> opts = PhxMediaLibrary.Storage.S3.options(provider: :r2, account_id: "abc", bucket: "media")
        iex> {opts[:endpoint], opts[:region], opts[:direct_upload]}
        {"https://abc.r2.cloudflarestorage.com", "auto", :put}

    """
    @spec options(keyword()) :: keyword()
    def options(opts) do
      opts = Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
      provider = Keyword.get(opts, :provider, :aws)

      preset =
        case Map.fetch(@presets, provider) do
          {:ok, preset} ->
            preset

          :error ->
            raise ArgumentError,
                  "unknown S3 provider #{inspect(provider)}; use :aws, :r2 or :generic " <>
                    "(any S3-compatible service works as :generic with an :endpoint)"
        end

      [provider: provider]
      |> Keyword.merge(preset)
      |> Keyword.merge(provider_endpoint(provider, opts))
      |> Keyword.merge(opts)
    end

    defp provider_endpoint(:r2, opts) do
      case {Keyword.get(opts, :account_id), Keyword.get(opts, :endpoint)} do
        {nil, nil} ->
          raise ArgumentError, "an S3 disk with provider: :r2 needs :account_id (or :endpoint)"

        {account_id, nil} ->
          [endpoint: "https://#{account_id}.r2.cloudflarestorage.com"]

        {_account_id, _endpoint} ->
          []
      end
    end

    defp provider_endpoint(_provider, _opts), do: []

    @impl true
    def put(path, content, opts) do
      opts = options(opts)
      bucket = Keyword.fetch!(opts, :bucket)
      # No ACL unless the disk sets one: AWS buckets with default settings
      # reject most ACLs, and R2 doesn't support them (ADR-025).
      upload_opts = Keyword.take(opts, [:acl, :cache_control])

      result =
        case content do
          {:stream, stream} ->
            # ExAws.S3.upload treats every element of the source stream as an
            # individual multipart part and uploads them concurrently.  It does
            # NOT rechunk the input.  Our MediaAdder streams files in 64 KiB
            # chunks (for checksum computation), so without rechunking every
            # part would be 64 KiB, well below the 5 MiB minimum that both
            # real AWS and LocalStack enforce.
            #
            # We rechunk the stream into @multipart_part_size binary parts
            # using Stream.transform/4 (Elixir ≥ 1.9).  The last part may be
            # smaller than the threshold, which S3 allows for the final part.
            stream
            |> rechunk(@multipart_part_size)
            |> ExAws.S3.upload(bucket, path, upload_opts)
            |> ExAws.request(ex_aws_opts(opts))

          binary when is_binary(binary) ->
            bucket
            |> ExAws.S3.put_object(path, binary, upload_opts)
            |> ExAws.request(ex_aws_opts(opts))
        end

      case result do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end

    @impl true
    def get(path, opts \\ []) do
      opts = options(opts)
      bucket = Keyword.fetch!(opts, :bucket)

      case bucket |> ExAws.S3.get_object(path) |> ExAws.request(ex_aws_opts(opts)) do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete(path, opts \\ []) do
      opts = options(opts)
      bucket = Keyword.fetch!(opts, :bucket)

      case bucket |> ExAws.S3.delete_object(path) |> ExAws.request(ex_aws_opts(opts)) do
        {:ok, _} -> :ok
        {:error, {:http_error, 404, _}} -> :ok
        {:error, _} = error -> error
      end
    end

    # HEAD for the size, then a ranged GET for the first bytes.
    @impl true
    def stat(path, header_bytes, opts) do
      opts = options(opts)
      bucket = Keyword.fetch!(opts, :bucket)
      request_opts = ex_aws_opts(opts)

      with {:ok, %{headers: headers}} <-
             bucket |> ExAws.S3.head_object(path) |> ExAws.request(request_opts),
           {size, ""} <- headers |> header_value("content-length") |> Integer.parse(),
           {:ok, header} <- read_header(bucket, path, size, header_bytes, request_opts) do
        {:ok, %{size: size, header: header}}
      else
        {:error, {:http_error, 404, _}} -> {:error, :not_found}
        {:error, _} = error -> error
        _unexpected -> {:error, :invalid_response}
      end
    end

    # A ranged GET on an empty object fails (416), and there's nothing to read.
    defp read_header(_bucket, _path, 0, _header_bytes, _request_opts), do: {:ok, <<>>}

    defp read_header(bucket, path, _size, header_bytes, request_opts) do
      case bucket
           |> ExAws.S3.get_object(path, range: "bytes=0-#{header_bytes - 1}")
           |> ExAws.request(request_opts) do
        {:ok, %{body: header}} -> {:ok, header}
        error -> error
      end
    end

    defp header_value(headers, name) do
      Enum.find_value(headers, "", fn {key, value} ->
        if String.downcase(key) == name, do: value
      end)
    end

    @impl true
    def exists?(path, opts \\ []) do
      opts = options(opts)
      bucket = Keyword.fetch!(opts, :bucket)

      case bucket |> ExAws.S3.head_object(path) |> ExAws.request(ex_aws_opts(opts)) do
        {:ok, _} -> true
        {:error, _} -> false
      end
    end

    @impl true
    def url(path, opts) do
      opts = options(opts)
      bucket = Keyword.fetch!(opts, :bucket)
      signed = Keyword.get(opts, :signed, false)
      download = Keyword.get(opts, :download, false)

      # S3 Content-Disposition overrides require a presigned URL, so
      # `download: true` implicitly forces signing.
      if signed or download do
        signed_url(bucket, path, opts)
      else
        public_url(bucket, path, opts)
      end
    end

    # S3 doesn't have local filesystem paths
    @impl true
    def path(_path, _opts), do: nil

    # Private functions

    # Public URLs are encoded here; ExAws encodes the keys it signs.
    defp public_url(bucket, path, opts) do
      path = PhxMediaLibrary.Storage.url_path(path)

      case {Keyword.get(opts, :base_url), opts[:provider], Keyword.get(opts, :endpoint)} do
        {nil, :r2, _endpoint} ->
          raise ArgumentError,
                "public URLs on an R2 disk need :base_url: R2 serves public files only " <>
                  "from a custom domain or an r2.dev URL (signed URLs work without it)"

        {nil, _provider, nil} ->
          region = Keyword.get(opts, :region, "us-east-1")
          "https://#{bucket}.s3.#{region}.amazonaws.com/#{path}"

        {nil, _provider, endpoint} ->
          endpoint_url(endpoint, bucket, path, opts[:addressing])

        {base_url, _provider, _endpoint} ->
          Path.join(base_url, path)
      end
    end

    defp endpoint_url(endpoint, bucket, path, :virtual_host) do
      uri = URI.parse(endpoint)
      URI.to_string(%{uri | host: "#{bucket}.#{uri.host}", path: "/#{path}"})
    end

    defp endpoint_url(endpoint, bucket, path, :path),
      do: "#{String.trim_trailing(endpoint, "/")}/#{bucket}/#{path}"

    # The disk's :direct_upload picks the method. A POST lets S3 enforce the
    # policy itself: the exact key, the size range and the content type. A
    # PUT, which R2 and B2 need, signs the key and the content type; it
    # can't limit the size, so the upload's completion checks it.
    @impl true
    def presigned_upload(path, presigned_opts, opts) do
      opts = options(opts)

      case opts[:direct_upload] do
        :post ->
          {:ok, url, fields} = presigned_post(path, presigned_opts, opts)
          {:ok, %{method: :post, url: url, fields: fields, headers: %{}}}

        :put ->
          presigned_put(path, presigned_opts, opts)

        other ->
          raise ArgumentError,
                "the S3 disk's :direct_upload must be :post or :put, got: #{inspect(other)}"
      end
    end

    # Deprecated callback: always a form POST.
    @impl true
    def presigned_upload_url(path, presigned_opts, opts),
      do: presigned_post(path, presigned_opts, options(opts))

    defp presigned_post(path, presigned_opts, opts) do
      bucket = Keyword.fetch!(opts, :bucket)
      content_type = Keyword.get(presigned_opts, :content_type)

      post_opts =
        [expires_in: Keyword.get(presigned_opts, :expires_in, 3600)]
        |> put_length_range(Keyword.get(presigned_opts, :content_length_range))
        |> put_content_type_condition(content_type)

      %{url: url, fields: fields} =
        ExAws.S3.presigned_post(
          ExAws.Config.new(:s3, ex_aws_opts(opts)),
          bucket,
          path,
          [virtual_host: opts[:addressing] == :virtual_host] ++ post_opts
        )

      # The client must send every field, including the Content-Type the
      # policy requires.
      fields = if content_type, do: Map.put(fields, "Content-Type", content_type), else: fields
      {:ok, url, fields}
    end

    defp presigned_put(path, presigned_opts, opts) do
      headers =
        case Keyword.get(presigned_opts, :content_type) do
          nil -> %{}
          content_type -> %{"content-type" => content_type}
        end

      case ExAws.S3.presigned_url(
             ExAws.Config.new(:s3, ex_aws_opts(opts)),
             :put,
             Keyword.fetch!(opts, :bucket),
             path,
             expires_in: Keyword.get(presigned_opts, :expires_in, 3600),
             virtual_host: opts[:addressing] == :virtual_host,
             headers: Map.to_list(headers)
           ) do
        {:ok, url} -> {:ok, %{method: :put, url: url, fields: %{}, headers: headers}}
        {:error, _} = error -> error
      end
    end

    defp put_length_range(post_opts, {min, max}),
      do: Keyword.put(post_opts, :content_length_range, [min, max])

    defp put_length_range(post_opts, nil), do: post_opts

    defp put_content_type_condition(post_opts, nil), do: post_opts

    defp put_content_type_condition(post_opts, content_type),
      do: Keyword.put(post_opts, :custom_conditions, [["eq", "$Content-Type", content_type]])

    defp signed_url(bucket, path, opts) do
      expires_in = Keyword.get(opts, :expires_in, 3600)
      download = Keyword.get(opts, :download, false)

      presign_opts =
        [expires_in: expires_in, virtual_host: opts[:addressing] == :virtual_host]
        |> maybe_add_response_content_disposition(path, opts, download)

      {:ok, url} =
        ExAws.S3.presigned_url(
          ExAws.Config.new(:s3, ex_aws_opts(opts)),
          :get,
          bucket,
          path,
          presign_opts
        )

      url
    end

    # Adds a `response-content-disposition` query param to the presigned URL
    # so that S3 instructs the browser to download the file rather than render it.
    # The param is included in the AWS Signature V4 canonical query string.
    defp maybe_add_response_content_disposition(presign_opts, path, opts, true) do
      filename = Keyword.get(opts, :filename, Path.basename(path))
      disposition = PhxMediaLibrary.FileName.content_disposition(filename)

      Keyword.put(presign_opts, :query_params, [{"response-content-disposition", disposition}])
    end

    defp maybe_add_response_content_disposition(presign_opts, _path, _opts, false) do
      presign_opts
    end

    defp ex_aws_opts(opts) do
      opts
      |> Keyword.take([:access_key_id, :secret_access_key, :region])
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Keyword.merge(endpoint_opts(Keyword.get(opts, :endpoint)))
      |> Keyword.put(:virtual_host, opts[:addressing] == :virtual_host)
    end

    defp endpoint_opts(nil), do: []

    defp endpoint_opts(endpoint) do
      case URI.parse(endpoint) do
        %URI{scheme: scheme, host: host, port: port}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          [scheme: scheme <> "://", host: host, port: port]

        _ ->
          raise ArgumentError,
                "the S3 disk's :endpoint must be an http(s) URL, got: #{inspect(endpoint)}"
      end
    end

    # ---------------------------------------------------------------------------
    # Stream rechunking helper
    # ---------------------------------------------------------------------------

    # Rechunks a stream of arbitrarily-sized binary chunks into parts of
    # exactly `part_size` bytes, with a potentially smaller final part.
    #
    # Stream.transform/5's last_fun flushes the remaining bytes as the final
    # part. (Its 4-arity form takes a cleanup function instead, whose result
    # is ignored: that dropped the tail of every upload before 0.9.0.) An
    # empty stream still yields one empty part, as a multipart upload needs
    # at least one.
    #
    # Memory profile: at most 2 × part_size bytes live in the accumulator
    # at any time (one full part being assembled + one incoming chunk).
    # Slice out as many full parts as `data` holds and keep the rest; with
    # less than one part, keep accumulating.
    defp split_parts(data, part_size) when byte_size(data) < part_size, do: {[], data}

    defp split_parts(data, part_size) do
      full_count = div(byte_size(data), part_size)
      parts = for i <- 0..(full_count - 1), do: binary_part(data, i * part_size, part_size)
      rest_offset = full_count * part_size
      {parts, binary_part(data, rest_offset, byte_size(data) - rest_offset)}
    end

    defp rechunk(stream, part_size) do
      Stream.transform(
        stream,
        # The buffer, and whether any part was emitted yet
        fn -> {<<>>, false} end,
        fn chunk, {buffer, emitted?} ->
          {parts, rest} = split_parts(buffer <> chunk, part_size)
          {parts, {rest, emitted? or parts != []}}
        end,
        fn
          {<<>>, true} -> {[], nil}
          {leftover, _emitted?} -> {[leftover], nil}
        end,
        fn _acc -> :ok end
      )
    end
  end
end
