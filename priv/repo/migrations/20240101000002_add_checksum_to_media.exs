defmodule PhxMediaLibrary.TestRepo.Migrations.AddChecksumToMedia do
  use Ecto.Migration

  def change do
    alter table(:media) do
      add(:checksum, :string)
      add(:checksum_algorithm, :string, default: "sha256")
    end

    create(index(:media, [:checksum]))
  end
end
