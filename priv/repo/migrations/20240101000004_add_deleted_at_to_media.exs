defmodule PhxMediaLibrary.TestRepo.Migrations.AddDeletedAtToMedia do
  use Ecto.Migration

  def change do
    alter table(:media) do
      add :deleted_at, :utc_datetime, null: true
    end

    create index(:media, [:deleted_at])
  end
end
