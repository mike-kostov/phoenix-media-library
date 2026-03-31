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
    - `:base_url` - Custom base URL (for CDN)
    - `:acl` - Default ACL for uploads (default: "private")

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

      upload_opts = [acl: acl]

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

    @impl true
    def presigned_upload_url(path, presigned_opts, opts) do
      bucket = Keyword.fetch!(opts, :bucket)
      expires_in = Keyword.get(presigned_opts, :expires_in, 3600)

      presign_opts =
        [expires_in: expires_in]
        |> maybe_add_content_type(presigned_opts)
        |> maybe_add_content_length_range(presigned_opts)

      config = ExAws.Config.new(:s3, ex_aws_opts(opts))

      case ExAws.S3.presigned_url(config, :put, bucket, path, presign_opts) do
        {:ok, url} ->
          fields = build_upload_fields(presigned_opts)
          {:ok, url, fields}

        {:error, _} = error ->
          error
      end
    end

    defp maybe_add_content_type(presign_opts, opts) do
      case Keyword.get(opts, :content_type) do
        nil -> presign_opts
        ct -> Keyword.put(presign_opts, :content_type, ct)
      end
    end

    defp maybe_add_content_length_range(presign_opts, opts) do
      case Keyword.get(opts, :content_length_range) do
        {_min, _max} = range ->
          Keyword.put(presign_opts, :content_length_range, range)

        nil ->
          presign_opts
      end
    end

    defp build_upload_fields(presigned_opts) do
      fields = %{}

      case Keyword.get(presigned_opts, :content_type) do
        nil -> fields
        ct -> Map.put(fields, "Content-Type", ct)
      end
    end

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
    defp rechunk(stream, part_size) do
      Stream.transform(
        stream,
        # start_fun — initial accumulator: empty binary buffer
        fn -> <<>> end,
        # reducer — called for each incoming chunk
        fn chunk, buffer ->
          data = buffer <> chunk

          if byte_size(data) >= part_size do
            # Slice out as many full parts as we can and keep the rest.
            full_count = div(byte_size(data), part_size)

            parts =
              for i <- 0..(full_count - 1) do
                binary_part(data, i * part_size, part_size)
              end

            rest_offset = full_count * part_size
            rest = binary_part(data, rest_offset, byte_size(data) - rest_offset)

            {parts, rest}
          else
            # Not enough data yet — keep accumulating.
            {[], data}
          end
        end,
        # last_fun — flush any remaining bytes as the final (possibly small) part
        fn
          <<>> -> {[], <<>>}
          leftover -> {[leftover], <<>>}
        end
      )
    end
  end
end
