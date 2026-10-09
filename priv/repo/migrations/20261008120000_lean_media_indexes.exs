defmodule PhxMediaLibrary.TestRepo.Migrations.LeanMediaIndexes do
  use Ecto.Migration

  # On Postgres the indexes are built and dropped CONCURRENTLY, which
  # can't run in a transaction: the table keeps taking writes. SQLite
  # has no CONCURRENTLY.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    concurrently = repo().__adapter__() == Ecto.Adapters.Postgres

    # The new index first, so lookups of trashed media always have one.
    create_if_not_exists(
      index(:media, [:deleted_at],
        where: "deleted_at IS NOT NULL",
        name: :media_deleted_at_partial_index,
        concurrently: concurrently
      )
    )

    drop_if_exists(index(:media, [:deleted_at], concurrently: concurrently))
    drop_if_exists(index(:media, [:mediable_type, :mediable_id], concurrently: concurrently))
    drop_if_exists(index(:media, [:collection_name], concurrently: concurrently))
    drop_if_exists(index(:media, [:checksum], concurrently: concurrently))
  end

  def down do
    concurrently = repo().__adapter__() == Ecto.Adapters.Postgres

    create_if_not_exists(index(:media, [:checksum], concurrently: concurrently))
    create_if_not_exists(index(:media, [:collection_name], concurrently: concurrently))

    create_if_not_exists(
      index(:media, [:mediable_type, :mediable_id], concurrently: concurrently)
    )

    create_if_not_exists(index(:media, [:deleted_at], concurrently: concurrently))

    drop_if_exists(
      index(:media, [:deleted_at],
        name: :media_deleted_at_partial_index,
        concurrently: concurrently
      )
    )
  end
end
