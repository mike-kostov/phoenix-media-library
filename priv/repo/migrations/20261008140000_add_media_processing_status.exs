defmodule PhxMediaLibrary.TestRepo.Migrations.AddMediaProcessingStatus do
  use Ecto.Migration

  # PhxMediaLibrary 0.10: Media.processing_status/1. Existing rows read
  # as done: processing_finished_at gets this migration's time as a
  # default, which Postgres stores once instead of rewriting the table,
  # and the default is dropped, so new rows start empty.
  def up do
    alter table(:media) do
      add :processing_started_at, :utc_datetime
      add :processing_finished_at, :utc_datetime, default: fragment("timezone('UTC', now())")
      add :processing_failed_at, :utc_datetime
      add :processing_error, :text
    end

    execute "ALTER TABLE media ALTER COLUMN processing_finished_at DROP DEFAULT"
  end

  def down do
    alter table(:media) do
      remove :processing_started_at
      remove :processing_finished_at
      remove :processing_failed_at
      remove :processing_error
    end
  end
end

