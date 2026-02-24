defmodule PhxMediaLibrary.Collection do
  @moduledoc """
  Represents a media collection configuration.

  Collections group related media and can have specific settings like
  allowed file types, storage disk, and file limits.
  """

  defstruct [
    :name,
    :disk,
    :accepts,
    :single_file,
    :max_files,
    :fallback_url,
    :fallback_path
  ]

  @type t :: %__MODULE__{
          name: atom(),
          disk: atom() | nil,
          accepts: [String.t()] | nil,
          single_file: boolean(),
          max_files: pos_integer() | nil,
          fallback_url: String.t() | nil,
          fallback_path: String.t() | nil
        }

  @doc """
  Create a new collection configuration.

  ## Options

  - `:disk` - Storage disk to use
  - `:accepts` - List of accepted MIME types
  - `:single_file` - Only keep one file (default: false)
  - `:max_files` - Maximum number of files
  - `:fallback_url` - URL when collection is empty
  - `:fallback_path` - Path when collection is empty

  """
  @spec new(atom(), keyword()) :: t()
  def new(name, opts \\ []) do
    %__MODULE__{
      name: name,
      disk: Keyword.get(opts, :disk),
      accepts: Keyword.get(opts, :accepts),
      single_file: Keyword.get(opts, :single_file, false),
      max_files: Keyword.get(opts, :max_files),
      fallback_url: Keyword.get(opts, :fallback_url),
      fallback_path: Keyword.get(opts, :fallback_path)
    }
  end
end
