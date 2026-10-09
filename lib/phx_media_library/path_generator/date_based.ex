defmodule PhxMediaLibrary.PathGenerator.DateBased do
  @moduledoc """
  Date-based path generator for PhxMediaLibrary.

  Organizes media files by their upload date, inserting a
  `{year}/{month}/{day}` prefix before the standard type/id/uuid hierarchy:

  - Original file: `{year}/{month}/{day}/{mediable_type}/{mediable_id}/{uuid}/{filename}`
  - Conversion:    `{year}/{month}/{day}/{mediable_type}/{mediable_id}/{uuid}/{base}_{conversion}{ext}`

  The date is the day the media was stored, its `inserted_at`, so a
  record's paths stay the same on every later day.

  ## Benefits

  - Easy to browse and archive files chronologically
  - Natural partitioning for backup and retention policies
  - Avoids hotspotting in storage systems with alphabetical key distribution
  - Clean lifecycle management: archive or delete entire date directories

  ## Examples

      iex> media = %PhxMediaLibrary.Media{
      ...>   mediable_type: "posts",
      ...>   mediable_id: "abc-123",
      ...>   uuid: "550e8400-e29b-41d4-a716-446655440000",
      ...>   file_name: "photo.jpg",
      ...>   inserted_at: ~U[2024-03-15 09:30:00Z]
      ...> }
      iex> PhxMediaLibrary.PathGenerator.DateBased.relative_path(media, nil)
      "2024/03/15/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo.jpg"

      iex> PhxMediaLibrary.PathGenerator.DateBased.relative_path(media, :thumb)
      "2024/03/15/posts/abc-123/550e8400-e29b-41d4-a716-446655440000/photo_thumb.jpg"

  ## Configuration

      config :phx_media_library,
        path_generator: PhxMediaLibrary.PathGenerator.DateBased

  ## Using with `path_context`

  You can supply a custom date via `path_context` to backfill or migrate
  media without stomping on the current date. The context key `:date` must
  be a `Date` struct:

      PhxMediaLibrary.PathGenerator.relative_path(media, :thumb, %{date: ~D[2023-01-01]})

  """

  @behaviour PhxMediaLibrary.PathGenerator

  alias PhxMediaLibrary.Media

  @impl true
  @doc """
  Generate the relative storage path for a media item.

  The date prefix (`{year}/{month}/{day}`) is the day of the media's
  `inserted_at`, when it was stored (today for media not stored yet).
  """
  @spec relative_path(Media.t(), atom() | String.t() | nil) :: String.t()
  def relative_path(%Media{} = media, conversion \\ nil) do
    relative_path(media, conversion, %{})
  end

  @impl true
  @doc """
  Generate the relative storage path with an optional path context.

  Accepts an optional `:date` key in `path_context` to override the upload
  date. When absent, the day of `inserted_at` is used (today without one).

  ## Example

      PhxMediaLibrary.PathGenerator.DateBased.relative_path(media, nil, %{date: ~D[2023-01-01]})
      # => "2023/01/01/posts/abc-123/uuid/photo.jpg"

  """
  @spec relative_path(Media.t(), atom() | String.t() | nil, map()) :: String.t()
  def relative_path(%Media{} = media, conversion, path_context) do
    date = Map.get(path_context, :date) || upload_date(media.inserted_at)
    date_prefix = date_path(date)

    base_path =
      Path.join([
        date_prefix,
        media.mediable_type,
        to_string(media.mediable_id),
        media.uuid
      ])

    filename = conversion_filename(media, conversion)
    Path.join(base_path, filename)
  end

  @impl true
  @doc """
  Generate a storage path for new media (before it has been persisted).

  The date prefix is the day of `attrs.inserted_at`, else today.
  """
  @spec for_new_media(map()) :: String.t()
  def for_new_media(attrs) do
    for_new_media(attrs, %{})
  end

  @impl true
  @doc """
  Generate a storage path for new media with an optional path context.

  Accepts an optional `:date` key in `path_context` to override the upload
  date. When absent, the day of `inserted_at` is used (today without one).
  """
  @spec for_new_media(map(), map()) :: String.t()
  def for_new_media(attrs, path_context) do
    date = Map.get(path_context, :date) || upload_date(attrs[:inserted_at])
    date_prefix = date_path(date)

    parts = [
      date_prefix,
      attrs.mediable_type,
      to_string(attrs.mediable_id),
      attrs.uuid,
      attrs.file_name
    ]

    Path.join(parts)
  end

  # Private helpers

  # The day the media was stored: a record's paths must not change with the
  # calendar. Today only for media without a time yet.
  defp upload_date(%DateTime{} = inserted_at), do: DateTime.to_date(inserted_at)
  defp upload_date(%NaiveDateTime{} = inserted_at), do: NaiveDateTime.to_date(inserted_at)
  defp upload_date(nil), do: Date.utc_today()

  defp date_path(%Date{year: year, month: month, day: day}) do
    Path.join([
      String.pad_leading(to_string(year), 4, "0"),
      String.pad_leading(to_string(month), 2, "0"),
      String.pad_leading(to_string(day), 2, "0")
    ])
  end

  defp conversion_filename(%Media{file_name: file_name}, nil), do: file_name

  defp conversion_filename(%Media{file_name: file_name}, conversion) do
    ext = Path.extname(file_name)
    base = Path.rootname(file_name)
    "#{base}_#{conversion}#{ext}"
  end
end
