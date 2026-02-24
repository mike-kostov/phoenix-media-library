defmodule PhxMediaLibrary.Storage.S3 do
  @moduledoc """
  Amazon S3 storage adapter.

  Requires `ex_aws` and `ex_aws_s3` dependencies.

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

  @impl true
  def put(path, content, opts) do
    unless Code.ensure_loaded?(ExAws.S3) do
      raise "ex_aws_s3 is required for S3 storage. Add {:ex_aws_s3, \"~> 2.5\"} to your dependencies."
    end

    bucket = Keyword.fetch!(opts, :bucket)
    acl = Keyword.get(opts, :acl, "private")

    upload_opts = [acl: acl]

    result =
      case content do
        {:stream, stream} ->
          stream
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

    if signed do
      signed_url(bucket, path, opts)
    else
      public_url(bucket, path, opts)
    end
  end

  # S3 doesn't have local filesystem paths
  # @impl true not needed since it's optional
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

  defp signed_url(bucket, path, opts) do
    expires_in = Keyword.get(opts, :expires_in, 3600)

    {:ok, url} =
      ExAws.S3.presigned_url(ExAws.Config.new(:s3, ex_aws_opts(opts)), :get, bucket, path,
        expires_in: expires_in
      )

    url
  end

  defp ex_aws_opts(opts) do
    opts
    |> Keyword.take([:access_key_id, :secret_access_key, :region])
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end
end
