defmodule PhxMediaLibrary.PathGenerator.Tenant do
  @moduledoc """
  Tenant-scoped path generator for PhxMediaLibrary.

  Produces paths prefixed with a `tenant_id` segment, isolating each
  tenant's files into a separate namespace within the same storage backend:

  - Original file: `{tenant_id}/{mediable_type}/{mediable_id}/{uuid}/{filename}`
  - Conversion:    `{tenant_id}/{mediable_type}/{mediable_id}/{uuid}/{base}_{conversion}{ext}`

  ## Tenant ID Resolution

  The `tenant_id` is read from the `path_context` map passed to the 3-arity
  `relative_path/3` and 2-arity `for_new_media/2` callbacks. Both atom keys
  (`:tenant_id`) and string keys (`"tenant_id"`) are supported:

      # Atom key
      PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{tenant_id: "acme"})

      # String key — useful when context comes from decoded JSON or params
      PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{"tenant_id" => "acme"})

  When no `tenant_id` is present in `path_context`, the generator falls back
  to the segment `"shared"` so that call sites that omit context continue to
  work rather than raising an error.

  Integer tenant IDs (`%{tenant_id: 42}`) are coerced to strings via
  `to_string/1`, producing `"42"` as the path segment.

  ## Examples

      iex> media = %PhxMediaLibrary.Media{
      ...>   mediable_type: "posts",
      ...>   mediable_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, nil, %{tenant_id: "acme"})
      "acme/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, :thumb, %{tenant_id: "acme"})
      "acme/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo_thumb.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, nil)
      "shared/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

  ## Configuration

      config :phx_media_library,
        path_generator: PhxMediaLibrary.PathGenerator.Tenant

  Once configured, pass a `path_context` map wherever you generate a path:

      PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{tenant_id: current_tenant.slug})

  See the [Multi-Tenant guide](guides/multi-tenant.md) for a full walkthrough.
  """

  @behaviour PhxMediaLibrary.PathGenerator

  alias PhxMediaLibrary.Media

  @impl true
  @doc """
  Generate the relative storage path for a media item without a path context.

  Delegates to `relative_path/3` with an empty context map, producing a
  `"shared"`-prefixed path.

  ## Examples

      iex> media = %PhxMediaLibrary.Media{
      ...>   mediable_type: "posts",
      ...>   mediable_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, nil)
      "shared/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, :thumb)
      "shared/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo_thumb.jpg"

  """
  @spec relative_path(Media.t(), atom() | String.t() | nil) :: String.t()
  def relative_path(%Media{} = media, conversion \\ nil) do
    relative_path(media, conversion, %{})
  end

  @impl true
  @doc """
  Generate the relative storage path for a media item with a path context.

  Reads `tenant_id` from `path_context` (atom or string key). Falls back to
  `"shared"` when neither key is present or both are `nil`.

  ## Examples

      iex> media = %PhxMediaLibrary.Media{
      ...>   mediable_type: "posts",
      ...>   mediable_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, nil, %{tenant_id: "acme"})
      "acme/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, :thumb, %{tenant_id: "acme"})
      "acme/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo_thumb.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, nil, %{"tenant_id" => "globex"})
      "globex/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.relative_path(media, nil, %{})
      "shared/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

  """
  @spec relative_path(Media.t(), atom() | String.t() | nil, map()) :: String.t()
  def relative_path(%Media{} = media, conversion, path_context) do
    tenant_id = extract_tenant_id(path_context)
    base_path = Path.join([tenant_id, media.mediable_type, media.mediable_id, media.uuid])
    filename = conversion_filename(media, conversion)
    Path.join(base_path, filename)
  end

  @impl true
  @doc """
  Generate a storage path for new media without a path context.

  Delegates to `for_new_media/2` with an empty context map, producing a
  `"shared"`-prefixed path.

  ## Example

      iex> attrs = %{
      ...>   mediable_type: "posts",
      ...>   mediable_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Tenant.for_new_media(attrs)
      "shared/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

  """
  @spec for_new_media(map()) :: String.t()
  def for_new_media(attrs) do
    for_new_media(attrs, %{})
  end

  @impl true
  @doc """
  Generate a storage path for new media with a path context.

  Reads `tenant_id` from `path_context` (atom or string key). Falls back to
  `"shared"` when neither key is present or both are `nil`.

  ## Examples

      iex> attrs = %{
      ...>   mediable_type: "posts",
      ...>   mediable_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Tenant.for_new_media(attrs, %{tenant_id: "acme"})
      "acme/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.for_new_media(attrs, %{"tenant_id" => "globex"})
      "globex/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Tenant.for_new_media(attrs, %{})
      "shared/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

  """
  @spec for_new_media(map(), map()) :: String.t()
  def for_new_media(attrs, path_context) do
    tenant_id = extract_tenant_id(path_context)
    Path.join([tenant_id, attrs.mediable_type, attrs.mediable_id, attrs.uuid, attrs.file_name])
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Prefers atom key `:tenant_id`, falls back to string key `"tenant_id"`.
  # Returns `"shared"` when neither key is present or the value is nil.
  defp extract_tenant_id(path_context) do
    case Map.get(path_context, :tenant_id, Map.get(path_context, "tenant_id")) do
      nil -> "shared"
      tenant_id -> to_string(tenant_id)
    end
  end

  defp conversion_filename(%Media{file_name: file_name}, nil), do: file_name

  defp conversion_filename(%Media{file_name: file_name}, conversion) do
    ext = Path.extname(file_name)
    base = Path.rootname(file_name)
    "#{base}_#{conversion}#{ext}"
  end
end
