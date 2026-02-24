defmodule PhxMediaLibrary.Storage.Memory do
  @moduledoc """
  In-memory storage adapter for testing.

  Files are stored in an Agent process and are lost when the process stops.

  ## Configuration

      config :phx_media_library,
        disks: [
          memory: [
            adapter: PhxMediaLibrary.Storage.Memory,
            base_url: "/test-uploads"
          ]
        ]

  ## Usage in Tests

      setup do
        PhxMediaLibrary.Storage.Memory.clear()
        :ok
      end

  """

  @behaviour PhxMediaLibrary.Storage

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Clear all stored files. Useful in test setup."
  def clear do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

    :ok
  end

  @doc "Get all stored files. Useful for debugging."
  def all do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
    else
      %{}
    end
  end

  @impl true
  def put(path, content, _opts) do
    ensure_started()

    data =
      case content do
        {:stream, stream} -> Enum.into(stream, <<>>)
        binary -> binary
      end

    Agent.update(__MODULE__, &Map.put(&1, path, data))
    :ok
  end

  @impl true
  def get(path, _opts \\ []) do
    ensure_started()

    case Agent.get(__MODULE__, &Map.get(&1, path)) do
      nil -> {:error, :not_found}
      data -> {:ok, data}
    end
  end

  @impl true
  def delete(path, _opts \\ []) do
    ensure_started()
    Agent.update(__MODULE__, &Map.delete(&1, path))
    :ok
  end

  @impl true
  def exists?(path, _opts \\ []) do
    ensure_started()
    Agent.get(__MODULE__, &Map.has_key?(&1, path))
  end

  @impl true
  def url(path, opts) do
    base_url = Keyword.get(opts, :base_url, "/memory")
    Path.join(base_url, path)
  end

  defp ensure_started do
    unless Process.whereis(__MODULE__) do
      {:ok, _} = start_link()
    end
  end
end
