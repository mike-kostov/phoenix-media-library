defmodule PhxMediaLibrary.Storage do
  @moduledoc """
  Behaviour for storage adapters.

  PhxMediaLibrary ships with the following adapters:

  - `PhxMediaLibrary.Storage.Disk` - Local filesystem (default)
  - `PhxMediaLibrary.Storage.S3` - Amazon S3 / compatible services
  - `PhxMediaLibrary.Storage.Memory` - In-memory storage (for testing)

  ## Implementing a Custom Adapter

      defmodule MyApp.Storage.CustomAdapter do
        @behaviour PhxMediaLibrary.Storage

        @impl true
        def put(path, content, opts) do
          # Store content at path
          :ok
        end

        # ... implement other callbacks
      end

  Then configure it:

      config :phx_media_library,
        disks: [
          custom: [
            adapter: MyApp.Storage.CustomAdapter,
            # adapter-specific options
          ]
        ]

  """

  @type path :: String.t()
  @type content :: binary() | {:stream, Enumerable.t()}
  @type opts :: keyword()

  @type url_opts :: [
          signed: boolean(),
          expires_in: pos_integer(),
          content_type: String.t(),
          disposition: String.t()
        ]

  @doc "Store content at the given path."
  @callback put(path(), content(), opts()) :: :ok | {:error, term()}

  @doc "Retrieve content from the given path."
  @callback get(path()) :: {:ok, binary()} | {:error, term()}

  @doc "Delete the file at the given path."
  @callback delete(path()) :: :ok | {:error, term()}

  @doc "Check if a file exists at the given path."
  @callback exists?(path()) :: boolean()

  @doc "Get a URL for the file."
  @callback url(path(), url_opts()) :: String.t()

  @doc "Get the full filesystem path (local storage only)."
  @callback path(path()) :: String.t() | nil

  @optional_callbacks [path: 1]
end
