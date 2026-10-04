defmodule PhxMediaLibrary.FakeS3Client do
  @moduledoc """
  An `ExAws.Request.HttpClient` for tests: answers HEAD and ranged GET
  requests from objects stored with `put_object/2`, and records every request.
  Enable it with `Application.put_env(:ex_aws, :http_client, __MODULE__)`.
  """

  @behaviour ExAws.Request.HttpClient

  @key {__MODULE__, :objects}

  @doc "Store an object under `key`, replacing all others; clears recorded requests."
  def put_object(key, content),
    do: :persistent_term.put(@key, %{objects: %{key => content}, requests: []})

  @doc "Forget all objects and requests."
  def reset, do: :persistent_term.put(@key, %{objects: %{}, requests: []})

  @doc "Requests seen so far, oldest first, as `{method, key}`."
  def requests, do: state().requests |> Enum.reverse()

  @impl true
  def request(method, url, _body, headers, _opts) do
    key = url |> URI.parse() |> Map.fetch!(:path) |> URI.decode()

    {object_key, content} =
      Enum.find(state().objects, {nil, nil}, fn {k, _} -> String.ends_with?(key, "/" <> k) end)

    record({method, object_key || key})
    respond(method, content, headers)
  end

  defp respond(_method, nil, _headers), do: {:ok, %{status_code: 404, headers: [], body: ""}}

  defp respond(:head, content, _headers),
    do:
      {:ok,
       %{
         status_code: 200,
         headers: [{"Content-Length", Integer.to_string(byte_size(content))}],
         body: ""
       }}

  defp respond(:get, content, headers) do
    {"range", "bytes=0-" <> last} =
      Enum.find(headers, fn {k, _} -> String.downcase(k) == "range" end)

    length = min(String.to_integer(last) + 1, byte_size(content))
    {:ok, %{status_code: 206, headers: [], body: binary_part(content, 0, length)}}
  end

  defp state, do: :persistent_term.get(@key, %{objects: %{}, requests: []})

  defp record(request) do
    current = state()
    :persistent_term.put(@key, %{current | requests: [request | current.requests]})
  end
end
