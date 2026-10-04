defmodule PhxMediaLibrary.TestNote do
  @moduledoc """
  A test schema with media but no conversions. Tests build it as a struct;
  it has no table.
  """

  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "notes" do
    field(:title, :string)
    has_media(:photos)
  end

  def media_collections do
    [collection(:photos, accepts: ~w(image/jpeg image/png))]
  end
end
