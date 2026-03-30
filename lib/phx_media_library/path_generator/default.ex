defmodule PhxMediaLibrary.PathGenerator.Default do
  @moduledoc """
  Default path generator for PhxMediaLibrary.

  Produces paths in the following format:

  - Original file: `{mediable_type}/{mediable_id}/{uuid}/{filename}`
  - Conversion:    `{mediable_type}/{mediable_id}/{uuid}/{base}_{conversion}{ext}`

  ## Examples

      iex> media = %PhxMediaLibrary.Media{
      ...>   mediable_type: "posts",
      ...>   mediable_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Default.relative_path(media, nil)
      "posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Default.relative_path(media, :thumb)
      "posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo_thumb.jpg"

  ## Configuration

      config :phx_media_library,
        path_generator: PhxMediaLibrary.PathGenerator.Default

  This is the default, so explicit configuration is only needed when
  switching back from a different generator.
  """

  @behaviour PhxMediaLibrary.PathGenerator

  alias PhxMediaLibrary.Media

  @impl true
  @doc """
  Generate the relative storage path for a media item.

  Produces `{mediable_type}/{mediable_id}/{uuid}/{filename}` for the original
  file and `{mediable_type}/{mediable_id}/{uuid}/{base}_{conversion}{ext}` for
  conversions.
  """
  @spec relative_path(Media.t(), atom() | String.t() | nil) :: String.t()
  def relative_path(%Media{} = media, conversion \\ nil) do
    base_path =
      Path.join([
        media.mediable_type,
        media.mediable_id,
        media.uuid
      ])

    filename = conversion_filename(media, conversion)
    Path.join(base_path, filename)
  end

  @impl true
  @doc """
  Generate a storage path for new media (before it has been persisted).

  Produces `{mediable_type}/{mediable_id}/{uuid}/{filename}`.
  """
  @spec for_new_media(map()) :: String.t()
  def for_new_media(attrs) do
    parts = [
      attrs.mediable_type,
      attrs.mediable_id,
      attrs.uuid,
      attrs.file_name
    ]

    Path.join(parts)
  end

  # Private helpers

  defp conversion_filename(%Media{file_name: file_name}, nil), do: file_name

  defp conversion_filename(%Media{file_name: file_name}, conversion) do
    ext = Path.extname(file_name)
    base = Path.rootname(file_name)
    "#{base}_#{conversion}#{ext}"
  end
end
