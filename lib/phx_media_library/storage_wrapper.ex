defmodule PhxMediaLibrary.StorageWrapper do
  @moduledoc false
  # Wraps a storage adapter to automatically pass config and emit Telemetry events.

  alias PhxMediaLibrary.Telemetry

  defstruct [:adapter, :config]

  def put(%__MODULE__{adapter: adapter, config: config}, path, content) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :put, path: path, adapter: adapter},
      fn ->
        result = adapter.put(path, content, config)
        {result, %{operation: :put, path: path, adapter: adapter}}
      end
    )
  end

  def get(%__MODULE__{adapter: adapter, config: config}, path) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :get, path: path, adapter: adapter},
      fn ->
        result = adapter.get(path, config)
        {result, %{operation: :get, path: path, adapter: adapter}}
      end
    )
  end

  def delete(%__MODULE__{adapter: adapter, config: config}, path) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :delete, path: path, adapter: adapter},
      fn ->
        result = adapter.delete(path, config)
        {result, %{operation: :delete, path: path, adapter: adapter}}
      end
    )
  end

  def exists?(%__MODULE__{adapter: adapter, config: config}, path) do
    Telemetry.span(
      [:phx_media_library, :storage],
      %{operation: :exists?, path: path, adapter: adapter},
      fn ->
        result = adapter.exists?(path, config)
        {result, %{operation: :exists?, path: path, adapter: adapter}}
      end
    )
  end

  # Size and first bytes of a stored object; adapters without stat/3 fall
  # back to reading the whole object.
  def stat(%__MODULE__{adapter: adapter, config: config}, path, header_bytes) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :stat, 3) do
      adapter.stat(path, header_bytes, config)
    else
      with {:ok, content} <- adapter.get(path, config) do
        size = byte_size(content)
        {:ok, %{size: size, header: binary_part(content, 0, min(size, header_bytes))}}
      end
    end
  end

  def url(%__MODULE__{adapter: adapter, config: config}, path, opts \\ []) do
    adapter.url(path, Keyword.merge(config, opts))
  end

  @doc """
  Sign a direct client-to-storage upload.

  Returns `{:ok, presigned_upload}`, or `{:error, :not_supported}` if the
  adapter can't sign uploads. Adapters with only the deprecated
  `presigned_upload_url/3` callback are treated as a form POST.
  """
  def presigned_upload(%__MODULE__{adapter: adapter, config: config}, path, presigned_opts) do
    Code.ensure_loaded(adapter)

    cond do
      function_exported?(adapter, :presigned_upload, 3) ->
        span(:presigned_upload, path, adapter, fn ->
          adapter.presigned_upload(path, presigned_opts, config)
        end)

      function_exported?(adapter, :presigned_upload_url, 3) ->
        span(:presigned_upload, path, adapter, fn ->
          adapter.presigned_upload_url(path, presigned_opts, config) |> as_form_post()
        end)

      true ->
        {:error, :not_supported}
    end
  end

  defp as_form_post({:ok, url, fields}),
    do: {:ok, %{method: :post, url: url, fields: fields, headers: %{}}}

  defp as_form_post({:error, _} = error), do: error

  defp span(operation, path, adapter, fun) do
    metadata = %{operation: operation, path: path, adapter: adapter}
    Telemetry.span([:phx_media_library, :storage], metadata, fn -> {fun.(), metadata} end)
  end

  @doc """
  Generate a presigned upload URL for direct client-to-storage uploads.

  Returns `{:ok, url, fields}` if the adapter supports presigned URLs,
  or `{:error, :not_supported}` if it doesn't.
  """
  def presigned_upload_url(
        %__MODULE__{adapter: adapter, config: config},
        path,
        presigned_opts \\ []
      ) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :presigned_upload_url, 3) do
      Telemetry.span(
        [:phx_media_library, :storage],
        %{operation: :presigned_upload_url, path: path, adapter: adapter},
        fn ->
          result = adapter.presigned_upload_url(path, presigned_opts, config)
          {result, %{operation: :presigned_upload_url, path: path, adapter: adapter}}
        end
      )
    else
      {:error, :not_supported}
    end
  end
end
