defmodule PhxMediaLibrary.TestRepo.Migrations.CreateMediaTable do
  use Ecto.Migration

  def change do
    create table(:media, primary_key: [type: :binary_id]) do
      add :uuid, :string, null: false
      add :collection_name, :string, null: false, default: "default"
      add :name, :string, null: false
      add :file_name, :string, null: false
      add :mime_type, :string, null: false
      add :disk, :string, null: false
      add :size, :bigint, null: false
      add :custom_properties, :map, default: %{}
      add :generated_conversions, :map, default: %{}
      add :responsive_images, :map, default: %{}
      add :order_column, :integer

      # Polymorphic association
      add :mediable_type, :string, null: false
      add :mediable_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media, [:uuid])
    create index(:media, [:mediable_type, :mediable_id])
    create index(:media, [:collection_name])
    create index(:media, [:mediable_type, :mediable_id, :collection_name])
  end
end
