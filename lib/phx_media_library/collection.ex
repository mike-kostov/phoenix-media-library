defmodule PhxMediaLibrary.Collection do
  @moduledoc """
  Represents a media collection configuration.

  Collections group related media and can have specific settings like
  allowed file types, storage disk, file limits, and size constraints.

  ## Fields

  - `:name` — the collection name atom (e.g. `:images`, `:documents`)
  - `:disk` — storage disk override for this collection
  - `:accepts` — list of accepted MIME types (e.g. `["image/jpeg", "image/png"]`)
  - `:single_file` — when `true`, only one file is kept in this collection (default: `false`)
  - `:max_files` — maximum number of files allowed in the collection
  - `:max_size` — maximum file size in bytes (e.g. `10_000_000` for 10 MB)
  - `:fallback_url` — URL to use when the collection is empty
  - `:fallback_path` — filesystem path to use when the collection is empty
  - `:verify_content_type` — when `true`, verify file content matches its declared MIME type (default: `true`)

  """

  defstruct [
    :name,
    :disk,
    :accepts,
    :single_file,
    :max_files,
    :max_size,
    :fallback_url,
    :fallback_path,
    :verify_content_type
  ]

  @type t :: %__MODULE__{
          name: atom(),
          disk: atom() | nil,
          accepts: [String.t()] | nil,
          single_file: boolean(),
          max_files: pos_integer() | nil,
          max_size: pos_integer() | nil,
          fallback_url: String.t() | nil,
          fallback_path: String.t() | nil,
          verify_content_type: boolean()
        }

  @doc """
  Create a new collection configuration.

  ## Options

  - `:disk` - Storage disk to use
  - `:accepts` - List of accepted MIME types
  - `:single_file` - Only keep one file (default: false)
  - `:max_files` - Maximum number of files
  - `:max_size` - Maximum file size in bytes (e.g. `10_000_000` for 10 MB)
  - `:fallback_url` - URL when collection is empty
  - `:fallback_path` - Path when collection is empty
  - `:verify_content_type` - Verify file content matches declared MIME type (default: true)

  ## Examples

      Collection.new(:images, accepts: ~w(image/jpeg image/png), max_size: 5_000_000)

      Collection.new(:avatar, single_file: true, max_size: 2_000_000)

      Collection.new(:documents,
        accepts: ~w(application/pdf),
        max_files: 10,
        max_size: 20_000_000,
        verify_content_type: true
      )

  """
  @spec new(atom(), keyword()) :: t()
  def new(name, opts \\ []) do
    %__MODULE__{
      name: name,
      disk: Keyword.get(opts, :disk),
      accepts: Keyword.get(opts, :accepts),
      single_file: Keyword.get(opts, :single_file, false),
      max_files: Keyword.get(opts, :max_files),
      max_size: Keyword.get(opts, :max_size),
      fallback_url: Keyword.get(opts, :fallback_url),
      fallback_path: Keyword.get(opts, :fallback_path),
      verify_content_type: Keyword.get(opts, :verify_content_type, true)
    }
  end
end
