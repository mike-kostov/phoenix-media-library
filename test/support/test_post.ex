defmodule PhxMediaLibrary.TestPost do
  @moduledoc """
  A test schema for testing media associations.
  """

  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "posts" do
    field(:title, :string)
    field(:body, :string)

    has_media()

    timestamps(type: :utc_datetime)
  end

  def media_collections do
    [
      collection(:images),
      collection(:documents, accepts: ~w(application/pdf text/plain)),
      collection(:avatar, single_file: true),
      collection(:gallery, max_files: 5)
    ]
  end

  def media_conversions do
    [
      conversion(:thumb, width: 150, height: 150, fit: :cover),
      conversion(:preview, width: 800, quality: 85),
      conversion(:banner, width: 1200, height: 400, fit: :crop, collections: [:images])
    ]
  end
end
