defmodule PhxMediaLibrary.TestRepo.Migrations.AddMetadataToMedia do
  use Ecto.Migration

  def change do
    alter table(:media) do
      add(:metadata, :map, default: %{})
    end
  end
end
