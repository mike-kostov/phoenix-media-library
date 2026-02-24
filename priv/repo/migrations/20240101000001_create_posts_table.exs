defmodule PhxMediaLibrary.TestRepo.Migrations.CreatePostsTable do
  use Ecto.Migration

  def change do
    create table(:posts, primary_key: [type: :binary_id]) do
      add :title, :string
      add :body, :text

      timestamps(type: :utc_datetime)
    end
  end
end
