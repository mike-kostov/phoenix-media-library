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

  @type presigned_opts :: [
          expires_in: pos_integer(),
          content_type: String.t(),
          content_length_range: {non_neg_integer(), pos_integer()}
        ]

  @doc "Store content at the given path."
  @callback put(path(), content(), opts()) :: :ok | {:error, term()}

  @doc "Retrieve content from the given path."
  @callback get(path(), opts()) :: {:ok, binary()} | {:error, term()}

  @doc "Delete the file at the given path."
  @callback delete(path(), opts()) :: :ok | {:error, term()}

  @doc "Check if a file exists at the given path."
  @callback exists?(path(), opts()) :: boolean()

  @doc "Get a URL for the file."
  @callback url(path(), opts()) :: String.t()

  @doc "Get the full filesystem path (local storage only)."
  @callback path(path(), opts()) :: String.t() | nil

  @doc """
  Generate a presigned URL for direct client-to-storage uploads.

  Returns `{:ok, url, fields}` where `url` is the upload endpoint and
  `fields` is a map of form fields the client sends with the file in a
  `multipart/form-data` POST.

  Only applicable to remote storage backends (e.g. S3). Local storage
  adapters do not need to implement this callback.

  ## Options

  - `:expires_in` — URL expiration in seconds (default: adapter-specific)
  - `:content_type` — expected content type of the upload
  - `:content_length_range` — `{min, max}` byte range tuple for upload size validation

  """
  @callback presigned_upload_url(path(), presigned_opts(), opts()) ::
              {:ok, String.t(), map()} | {:error, term()}

  @doc """
  Return a stored object's size and its first bytes (up to `header_bytes`),
  without reading the whole object.

  Used to check direct uploads against their collection's rules. Adapters
  that don't implement it fall back to `get/2`, which reads the whole
  object.
  """
  @callback stat(path(), header_bytes :: pos_integer(), opts()) ::
              {:ok, %{size: non_neg_integer(), header: binary()}} | {:error, term()}

  @optional_callbacks [path: 2, presigned_upload_url: 3, stat: 3]
end
