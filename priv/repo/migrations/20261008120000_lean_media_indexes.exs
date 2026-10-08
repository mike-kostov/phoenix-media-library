defmodule PhxMediaLibrary.TestRepo.Migrations.LeanMediaIndexes do
  use Ecto.Migration

  # Concurrent index builds can't run in a transaction; the table keeps
  # taking writes while they run.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # The new index first, so lookups of trashed media always have one.
    create_if_not_exists index(:media, [:deleted_at],
                           where: "deleted_at IS NOT NULL",
                           name: :media_deleted_at_partial_index,
                           concurrently: true
                         )

    drop_if_exists index(:media, [:deleted_at], concurrently: true)
    drop_if_exists index(:media, [:mediable_type, :mediable_id], concurrently: true)
    drop_if_exists index(:media, [:collection_name], concurrently: true)
    drop_if_exists index(:media, [:checksum], concurrently: true)
  end

  def down do
    create_if_not_exists index(:media, [:checksum], concurrently: true)
    create_if_not_exists index(:media, [:collection_name], concurrently: true)
    create_if_not_exists index(:media, [:mediable_type, :mediable_id], concurrently: true)
    create_if_not_exists index(:media, [:deleted_at], concurrently: true)

    drop_if_exists index(:media, [:deleted_at],
                     name: :media_deleted_at_partial_index,
                     concurrently: true
                   )
  end
end

