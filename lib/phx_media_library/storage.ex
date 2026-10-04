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

  @typedoc """
  A signed direct upload: the browser sends the file to `url` with
  `method`. For `:post`, a `multipart/form-data` form with every entry of
  `fields` and the file last; for `:put`, the file as the body with every
  entry of `headers`.
  """
  @type presigned_upload :: %{
          method: :post | :put,
          url: String.t(),
          fields: %{optional(String.t()) => String.t()},
          headers: %{optional(String.t()) => String.t()}
        }

  @doc """
  Sign a direct client-to-storage upload of `path`.

  The adapter picks the method (for S3, the disk's `:direct_upload`). Only
  applicable to remote storage backends (e.g. S3). Local storage adapters
  do not need to implement this callback.

  ## Options

  - `:expires_in` — URL expiration in seconds (default: adapter-specific)
  - `:content_type` — content type the upload must have
  - `:content_length_range` — `{min, max}` byte range, where the method
    can enforce it

  """
  @callback presigned_upload(path(), presigned_opts(), opts()) ::
              {:ok, presigned_upload()} | {:error, term()}

  @doc """
  Deprecated: implement `presigned_upload/3` instead. Adapters that only
  implement this callback keep working, as a form POST, until 0.10.0.

  Returns `{:ok, url, fields}` where `url` is the upload endpoint and
  `fields` is a map of form fields the client sends with the file in a
  `multipart/form-data` POST.

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

  @optional_callbacks [path: 2, presigned_upload: 3, presigned_upload_url: 3, stat: 3]

  @doc """
  Percent-encode each segment of a storage path for use in a URL.

  Media stored before 0.9 kept the uploaded name, which can contain spaces,
  `#`, `?` or non-ASCII letters. Adapters build their URLs with this.

  ## Examples

      iex> PhxMediaLibrary.Storage.url_path("posts/1/Report #3.pdf")
      "posts/1/Report%20%233.pdf"

      iex> PhxMediaLibrary.Storage.url_path("posts/1/рокля.jpg")
      "posts/1/%D1%80%D0%BE%D0%BA%D0%BB%D1%8F.jpg"

  """
  @spec url_path(path()) :: String.t()
  def url_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end
end
