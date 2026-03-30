defmodule PhxMediaLibrary.PathGenerator.Flat do
  @moduledoc """
  Flat path generator for PhxMediaLibrary.

  Produces a minimal two-segment path using only the media UUID, deliberately
  omitting the mediable type and ID hierarchy:

  - Original file: `{uuid}/{filename}`
  - Conversion:    `{uuid}/{base}_{conversion}{ext}`

  This is useful when you want a uniform, non-hierarchical storage structure,
  for example in S3 buckets where access control is managed at the bucket level
  rather than via path prefixes, or when you want to avoid exposing model
  structure in your storage layout.

  ## Examples

      iex> media = %PhxMediaLibrary.Media{
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg"
      ...> }
      iex> PhxMediaLibrary.PathGenerator.Flat.relative_path(media, nil)
      "550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.Flat.relative_path(media, :thumb)
      "550e8400-e29b-41d4-a716-446655440000/photo_thumb.jpg"

  ## Configuration

      config :phx_media_library,
        path_generator: PhxMediaLibrary.PathGenerator.Flat

  """

  @behaviour PhxMediaLibrary.PathGenerator

  alias PhxMediaLibrary.Media

  @impl true
  @doc """
  Generate the relative storage path for a media item.

  Produces `{uuid}/{filename}` for the original file and
  `{uuid}/{base}_{conversion}{ext}` for conversions.
  """
  @spec relative_path(Media.t(), atom() | String.t() | nil) :: String.t()
  def relative_path(%Media{} = media, conversion \\ nil) do
    filename = conversion_filename(media, conversion)
    Path.join(media.uuid, filename)
  end

  @impl true
  @doc """
  Generate a storage path for new media (before it has been persisted).

  Produces `{uuid}/{filename}`.
  """
  @spec for_new_media(map()) :: String.t()
  def for_new_media(attrs) do
    Path.join(attrs.uuid, attrs.file_name)
  end

  # Private helpers

  defp conversion_filename(%Media{file_name: file_name}, nil), do: file_name

  defp conversion_filename(%Media{file_name: file_name}, conversion) do
    ext = Path.extname(file_name)
    base = Path.rootname(file_name)
    "#{base}_#{conversion}#{ext}"
  end
end
