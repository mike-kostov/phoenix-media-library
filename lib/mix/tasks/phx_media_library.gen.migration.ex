defmodule Mix.Tasks.PhxMediaLibrary.Gen.Migration do
  @moduledoc """
  Generates a new PhxMediaLibrary migration.

  This task is useful for adding new columns or indexes to the media table
  after the initial installation.

  ## Usage

      $ mix phx_media_library.gen.migration add_custom_field

  ## Upgrades

      $ mix phx_media_library.gen.migration --indexes

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
    {opts, rest, _} = OptionParser.parse(args, strict: [indexes: :boolean, table: :string])

    case {opts[:indexes], rest} do
      {true, _} ->
        generate_indexes_migration(opts[:table] || "media")

      {_, [name | _]} ->
        generate_migration(name)

      {_, []} ->
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

  defp generate_indexes_migration(table) do
    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)
    path = Path.join(migrations_path, "#{generate_timestamp()}_lean_media_indexes.exs")

    create_file(path, lean_indexes_template(table))
    Mix.shell().info("Created #{path}")
  end

  @doc false
  def lean_indexes_template(table) do
    """
    defmodule #{inspect(repo_module())}.Migrations.LeanMediaIndexes do
      use Ecto.Migration

      # Concurrent index builds can't run in a transaction; the table keeps
      # taking writes while they run.
      @disable_ddl_transaction true
      @disable_migration_lock true

      def up do
        # The new index first, so lookups of trashed media always have one.
        create_if_not_exists index(:#{table}, [:deleted_at],
                               where: "deleted_at IS NOT NULL",
                               name: :#{table}_deleted_at_partial_index,
                               concurrently: true
                             )

        drop_if_exists index(:#{table}, [:deleted_at], concurrently: true)
        drop_if_exists index(:#{table}, [:mediable_type, :mediable_id], concurrently: true)
        drop_if_exists index(:#{table}, [:collection_name], concurrently: true)
        drop_if_exists index(:#{table}, [:checksum], concurrently: true)
      end

      def down do
        create_if_not_exists index(:#{table}, [:checksum], concurrently: true)
        create_if_not_exists index(:#{table}, [:collection_name], concurrently: true)
        create_if_not_exists index(:#{table}, [:mediable_type, :mediable_id], concurrently: true)
        create_if_not_exists index(:#{table}, [:deleted_at], concurrently: true)

        drop_if_exists index(:#{table}, [:deleted_at],
                         name: :#{table}_deleted_at_partial_index,
                         concurrently: true
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
