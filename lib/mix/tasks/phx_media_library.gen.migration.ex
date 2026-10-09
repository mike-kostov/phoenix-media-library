defmodule Mix.Tasks.PhxMediaLibrary.Gen.Migration do
  @moduledoc """
  Generates a new PhxMediaLibrary migration.

  This task is useful for adding new columns or indexes to the media table
  after the initial installation.

  ## Usage

      $ mix phx_media_library.gen.migration add_custom_field

  ## Upgrades

      $ mix phx_media_library.gen.migration --indexes

      $ mix phx_media_library.gen.migration --processing-status

  `--processing-status` generates the required 0.10 upgrade: the columns
  of `PhxMediaLibrary.Media.processing_status/1`. Existing rows read as
  done; Postgres stores that once, without rewriting the table.

  `--indexes` generates the optional 0.10 upgrade of the media table's
  indexes: it drops (mediable_type, mediable_id), (collection_name) and
  (checksum), which no library query needs, and makes (deleted_at) a
  partial index. Every upload then writes fewer index entries
  (`docs/ideas/db-performance.md` measured a third less WAL). The
  migration builds and drops `CONCURRENTLY`, so large tables keep taking
  writes; `--table NAME` for a renamed media table. Keep the checksum
  index if your app looks media up by checksum.

  """

  @shortdoc "Generates a new PhxMediaLibrary migration"

  use Mix.Task

  import Mix.Generator

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [indexes: :boolean, processing_status: :boolean, table: :string]
      )

    table = opts[:table] || "media"

    case {opts[:indexes], opts[:processing_status], rest} do
      {true, _, _} ->
        generate_upgrade("lean_media_indexes", lean_indexes_template(table))

      {_, true, _} ->
        generate_upgrade("add_media_processing_status", processing_status_template(table))

      {_, _, [name | _]} ->
        generate_migration(name)

      {_, _, []} ->
        Mix.shell().error("Usage: mix phx_media_library.gen.migration <name>")
        exit(:shutdown)
    end
  end

  defp generate_migration(name) do
    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)

    timestamp = generate_timestamp()
    snake_name = Macro.underscore(name)
    filename = "#{timestamp}_#{snake_name}.exs"
    path = Path.join(migrations_path, filename)

    module_name = Macro.camelize(name)

    content = """
    defmodule #{inspect(repo_module())}.Migrations.#{module_name} do
      use Ecto.Migration

      def change do
        alter table(:media) do
          # Add your changes here
          # add :new_field, :string
        end

        # Add indexes if needed
        # create index(:media, [:new_field])
      end
    end
    """

    create_file(path, content)
    Mix.shell().info("Created #{path}")
  end

  defp generate_upgrade(name, content) do
    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)
    path = Path.join(migrations_path, "#{generate_timestamp()}_#{name}.exs")

    create_file(path, content)
    Mix.shell().info("Created #{path}")
  end

  @doc false
  def processing_status_template(table) do
    """
    defmodule #{inspect(repo_module())}.Migrations.AddMediaProcessingStatus do
      use Ecto.Migration

      # PhxMediaLibrary 0.10: Media.processing_status/1. Existing rows read
      # as done. On Postgres, processing_finished_at gets this migration's
      # time as a default, which Postgres stores once instead of rewriting
      # the table, and the default is dropped, so new rows start empty.
      # SQLite can't drop a default, so it marks the rows in an UPDATE.
      def up do
        postgres? = repo().__adapter__() == Ecto.Adapters.Postgres

        alter table(:#{table}) do
          add :processing_started_at, :utc_datetime

          add :processing_finished_at, :utc_datetime,
            default: if(postgres?, do: fragment("timezone('UTC', now())"))

          add :processing_failed_at, :utc_datetime
          add :processing_error, :text
        end

        if postgres?,
          do: execute("ALTER TABLE #{table} ALTER COLUMN processing_finished_at DROP DEFAULT"),
          else: execute("UPDATE #{table} SET processing_finished_at = inserted_at")
      end

      def down do
        alter table(:#{table}) do
          remove :processing_started_at
          remove :processing_finished_at
          remove :processing_failed_at
          remove :processing_error
        end
      end
    end
    """
  end

  @doc false
  def lean_indexes_template(table) do
    """
    defmodule #{inspect(repo_module())}.Migrations.LeanMediaIndexes do
      use Ecto.Migration

      # On Postgres the indexes are built and dropped CONCURRENTLY, which
      # can't run in a transaction: the table keeps taking writes. SQLite
      # has no CONCURRENTLY.
      @disable_ddl_transaction true
      @disable_migration_lock true

      def up do
        concurrently = repo().__adapter__() == Ecto.Adapters.Postgres

        # The new index first, so lookups of trashed media always have one.
        create_if_not_exists index(:#{table}, [:deleted_at],
                               where: "deleted_at IS NOT NULL",
                               name: :#{table}_deleted_at_partial_index,
                               concurrently: concurrently
                             )

        drop_if_exists index(:#{table}, [:deleted_at], concurrently: concurrently)
        drop_if_exists index(:#{table}, [:mediable_type, :mediable_id], concurrently: concurrently)
        drop_if_exists index(:#{table}, [:collection_name], concurrently: concurrently)
        drop_if_exists index(:#{table}, [:checksum], concurrently: concurrently)
      end

      def down do
        concurrently = repo().__adapter__() == Ecto.Adapters.Postgres

        create_if_not_exists index(:#{table}, [:checksum], concurrently: concurrently)
        create_if_not_exists index(:#{table}, [:collection_name], concurrently: concurrently)
        create_if_not_exists index(:#{table}, [:mediable_type, :mediable_id], concurrently: concurrently)
        create_if_not_exists index(:#{table}, [:deleted_at], concurrently: concurrently)

        drop_if_exists index(:#{table}, [:deleted_at],
                         name: :#{table}_deleted_at_partial_index,
                         concurrently: concurrently
                       )
      end
    end
    """
  end

  defp generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"

  defp repo_module do
    app = Mix.Project.config()[:app]
    app_module = app |> to_string() |> Macro.camelize() |> String.to_atom()
    Module.concat([app_module, Repo])
  end
end
