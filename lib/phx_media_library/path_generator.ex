defmodule PhxMediaLibrary.PathGenerator do
  @moduledoc """
  Behaviour for generating storage paths for media files, plus a set of
  delegating functions that route calls to the configured implementation.

  ## Built-in generators

    * `PhxMediaLibrary.PathGenerator.Default` — `{type}/{id}/{uuid}/{filename}` (the default)
    * `PhxMediaLibrary.PathGenerator.Flat` — `{uuid}/{filename}`
    * `PhxMediaLibrary.PathGenerator.DateBased` — `{year}/{month}/{day}/{type}/{id}/{uuid}/{filename}`

  ## Configuring a custom generator

      config :phx_media_library,
        path_generator: PhxMediaLibrary.PathGenerator.DateBased

  ## Writing a custom generator

  Implement the `PhxMediaLibrary.PathGenerator` behaviour and configure it:

      defmodule MyApp.TenantPathGenerator do
        @behaviour PhxMediaLibrary.PathGenerator

        @impl true
        def relative_path(media, conversion) do
          relative_path(media, conversion, %{})
        end

        @impl true
        def relative_path(media, conversion, path_context) do
          tenant_id = Map.get(path_context, :tenant_id, "shared")
          base = Path.join([to_string(tenant_id), media.mediable_type, media.mediable_id, media.uuid])
          ext = Path.extname(media.file_name)
          name = Path.rootname(media.file_name)
          filename = if conversion, do: "\#{name}_\#{conversion}\#{ext}", else: media.file_name
          Path.join(base, filename)
        end

        @impl true
        def for_new_media(attrs), do: for_new_media(attrs, %{})

        @impl true
        def for_new_media(attrs, path_context) do
          tenant_id = Map.get(path_context, :tenant_id, "shared")
          Path.join([to_string(tenant_id), attrs.mediable_type, attrs.mediable_id, attrs.uuid, attrs.file_name])
        end
      end

  Then configure:

      config :phx_media_library,
        path_generator: MyApp.TenantPathGenerator

  And pass context when generating paths:

      PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{tenant_id: "acme"})

  ## The `path_context` escape hatch

  The optional `path_context` map lets you thread arbitrary data — such as
  `tenant_id`, `user_id`, or `space_id` — into a custom path generator without
  coupling to `custom_properties` or the media schema itself.

  The built-in generators ignore `path_context`; custom generators may use it
  however they like.

  The 3-arity forms of `relative_path/3` and `for_new_media/2` are
  `@optional_callbacks`. If your generator does not implement them, calls that
  supply a `path_context` fall back gracefully to the 2-arity / 1-arity forms.
  """

  alias PhxMediaLibrary.{Config, Media}

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Generate the relative storage path for a media item.
  """
  @callback relative_path(media :: Media.t(), conversion :: atom() | String.t() | nil) ::
              String.t()

  @doc """
  Generate the relative storage path for a media item with an optional path
  context map.

  This is an **optional** callback. When not implemented, callers that supply
  a `path_context` will automatically fall back to `relative_path/2`.
  """
  @callback relative_path(
              media :: Media.t(),
              conversion :: atom() | String.t() | nil,
              path_context :: map()
            ) :: String.t()

  @doc """
  Generate a storage path for new media (before the record has been persisted).
  """
  @callback for_new_media(attrs :: map()) :: String.t()

  @doc """
  Generate a storage path for new media with an optional path context map.

  This is an **optional** callback. When not implemented, callers that supply
  a `path_context` will automatically fall back to `for_new_media/1`.
  """
  @callback for_new_media(attrs :: map(), path_context :: map()) :: String.t()

  @optional_callbacks [relative_path: 3, for_new_media: 2]

  # ---------------------------------------------------------------------------
  # Delegating functions — route to the configured implementation
  # ---------------------------------------------------------------------------

  @doc """
  Generate the relative storage path for a media item.

  Delegates to the configured path generator
  (see `PhxMediaLibrary.Config.path_generator/0`).

  ## Example

      iex> PhxMediaLibrary.PathGenerator.relative_path(media, nil)
      "posts/abc-123/uuid/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.relative_path(media, :thumb)
      "posts/abc-123/uuid/photo_thumb.jpg"

  """
  @spec relative_path(Media.t(), atom() | String.t() | nil) :: String.t()
  def relative_path(%Media{} = media, conversion \\ nil) do
    Config.path_generator().relative_path(media, conversion)
  end

  @doc """
  Generate the relative storage path for a media item with extra path context.

  Falls back to `relative_path/2` if the configured generator does not
  implement the optional 3-arity callback.

  ## Example

      iex> PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{tenant_id: "acme"})
      "acme/posts/abc-123/uuid/photo_thumb.jpg"

  """
  @spec relative_path(Media.t(), atom() | String.t() | nil, map()) :: String.t()
  def relative_path(%Media{} = media, conversion, path_context) do
    gen = Config.path_generator()
    Code.ensure_loaded(gen)

    if function_exported?(gen, :relative_path, 3) do
      gen.relative_path(media, conversion, path_context)
    else
      gen.relative_path(media, conversion)
    end
  end

  @doc """
  Generate a storage path for new media (before it has been persisted).

  Delegates to the configured path generator.
  """
  @spec for_new_media(map()) :: String.t()
  def for_new_media(attrs) do
    Config.path_generator().for_new_media(attrs)
  end

  @doc """
  Generate a storage path for new media with extra path context.

  Falls back to `for_new_media/1` if the configured generator does not
  implement the optional 2-arity callback.
  """
  @spec for_new_media(map(), map()) :: String.t()
  def for_new_media(attrs, path_context) do
    gen = Config.path_generator()
    Code.ensure_loaded(gen)

    if function_exported?(gen, :for_new_media, 2) do
      gen.for_new_media(attrs, path_context)
    else
      gen.for_new_media(attrs)
    end
  end

  @doc """
  Get the full filesystem path for a media item (local storage only).

  Returns `nil` if the configured storage adapter for `media.disk` does not
  expose a local path (e.g. S3).

  ## Example

      iex> PhxMediaLibrary.PathGenerator.full_path(media, nil)
      "/app/priv/static/uploads/posts/abc-123/uuid/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.full_path(media, :thumb)
      "/app/priv/static/uploads/posts/abc-123/uuid/photo_thumb.jpg"

  """
  @spec full_path(Media.t(), atom() | nil) :: String.t() | nil
  def full_path(%Media{disk: disk} = media, conversion) do
    storage = Config.storage_adapter(disk)
    relative = relative_path(media, conversion)

    # Ensure the adapter module is loaded before checking for the optional
    # path/2 callback. function_exported?/3 does not auto-load modules.
    Code.ensure_loaded(storage.adapter)

    if function_exported?(storage.adapter, :path, 2) do
      storage.adapter.path(relative, storage.config)
    else
      nil
    end
  end

  @doc """
  Get the full filesystem path for a media item with extra path context
  (local storage only).

  Returns `nil` if the configured storage adapter does not expose a local
  path (e.g. S3).
  """
  @spec full_path(Media.t(), atom() | nil, map()) :: String.t() | nil
  def full_path(%Media{disk: disk} = media, conversion, path_context) do
    storage = Config.storage_adapter(disk)
    relative = relative_path(media, conversion, path_context)

    Code.ensure_loaded(storage.adapter)

    if function_exported?(storage.adapter, :path, 2) do
      storage.adapter.path(relative, storage.config)
    else
      nil
    end
  end
end
