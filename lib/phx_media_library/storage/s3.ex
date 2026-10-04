if Code.ensure_loaded?(ExAws.S3) do
  defmodule PhxMediaLibrary.Storage.S3 do
    @moduledoc """
    Amazon S3 storage adapter.

    Requires `ex_aws` and `ex_aws_s3` dependencies. This module is only
    compiled when `:ex_aws_s3` is available. If it is not installed,
    the module simply does not exist — configuring an S3 disk without the
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
            ]
          ]

    ## Options

    - `:bucket` - S3 bucket name (required)
    - `:region` - AWS region (default: from ExAws config)
    - `:endpoint` - API URL of an S3-compatible service, e.g.
      `"https://<account_id>.r2.cloudflarestorage.com"` (default: AWS).
      Requests use path-style addressing (`<endpoint>/<bucket>/<key>`),
      ExAws's default
    - `:base_url` - Custom base URL (for CDN)
    - `:acl` - Default ACL for uploads (default: "private")
    - `:cache_control` - `Cache-Control` header stored with every upload,
      e.g. `"public, max-age=31536000, immutable"` for files served through
      a CDN with `cache_bust: true` URLs (default: none)

    """

    @behaviour PhxMediaLibrary.Storage

    # Minimum multipart part size imposed by S3 (and LocalStack).
    # Every part except the last must be >= 5 MiB; we target exactly this
    # so that even the last part of a very large file stays on the safe side.
    @multipart_part_size 5 * 1024 * 1024

    @impl true
    def put(path, content, opts) do
      bucket = Keyword.fetch!(opts, :bucket)
      acl = Keyword.get(opts, :acl, "private")

      upload_opts =
        case Keyword.get(opts, :cache_control) do
          nil -> [acl: acl]
          cache_control -> [acl: acl, cache_control: cache_control]
        end

      result =
        case content do
          {:stream, stream} ->
            # ExAws.S3.upload treats every element of the source stream as an
            # individual multipart part and uploads them concurrently.  It does
            # NOT rechunk the input.  Our MediaAdder streams files in 64 KiB
            # chunks (for checksum computation), so without rechunking every
            # part would be 64 KiB — well below the 5 MiB minimum that both
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
      bucket = Keyword.fetch!(opts, :bucket)

      case bucket |> ExAws.S3.get_object(path) |> ExAws.request(ex_aws_opts(opts)) do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete(path, opts \\ []) do
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
      bucket = Keyword.fetch!(opts, :bucket)

      case bucket |> ExAws.S3.head_object(path) |> ExAws.request(ex_aws_opts(opts)) do
        {:ok, _} -> true
        {:error, _} -> false
      end
    end

    @impl true
    def url(path, opts) do
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

    defp public_url(bucket, path, opts) do
      case Keyword.get(opts, :base_url) do
        nil ->
          region = Keyword.get(opts, :region, "us-east-1")
          "https://#{bucket}.s3.#{region}.amazonaws.com/#{path}"

        base_url ->
          Path.join(base_url, path)
      end
    end

    # A presigned POST (not PUT) so S3 itself enforces the policy: the exact
    # key, the size range and the content type. A presigned PUT can't limit
    # the size at all.
    @impl true
    def presigned_upload_url(path, presigned_opts, opts) do
      bucket = Keyword.fetch!(opts, :bucket)
      content_type = Keyword.get(presigned_opts, :content_type)

      post_opts =
        [expires_in: Keyword.get(presigned_opts, :expires_in, 3600)]
        |> put_length_range(Keyword.get(presigned_opts, :content_length_range))
        |> put_content_type_condition(content_type)

      %{url: url, fields: fields} =
        ExAws.S3.presigned_post(ExAws.Config.new(:s3, ex_aws_opts(opts)), bucket, path, post_opts)

      # The client must send every field, including the Content-Type the
      # policy requires.
      fields = if content_type, do: Map.put(fields, "Content-Type", content_type), else: fields
      {:ok, url, fields}
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
        [expires_in: expires_in]
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
      safe_name = String.replace(filename, ~s("), ~s(\\"))
      disposition = ~s(attachment; filename="#{safe_name}")

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
    # Uses Stream.transform/4 (start_fun, reducer, last_fun) so the
    # accumulated buffer is flushed as a final emission when the source
    # stream is exhausted — ensuring we never silently drop the tail of
    # an upload.
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
        # start_fun — initial accumulator: empty binary buffer
        fn -> <<>> end,
        # reducer — called for each incoming chunk
        fn chunk, buffer -> split_parts(buffer <> chunk, part_size) end,
        # last_fun — flush any remaining bytes as the final (possibly small) part
        fn
          <<>> -> {[], <<>>}
          leftover -> {[leftover], <<>>}
        end
      )
    end
  end
end
