defmodule Mix.Tasks.PhxMediaLibrary.Install do
  @moduledoc """
  Installs PhxMediaLibrary in your project.

  This task will:
  1. Generate the media table migration
  2. Print configuration instructions

  ## Usage

      $ mix phx_media_library.install

  ## Options

      --no-migration        Skip migration generation
      --id-type TYPE        Type for the mediable_id column: binary_id (default), integer, string
      --binary-id BOOL      Deprecated — use --id-type instead (false maps to --id-type integer)
      --table NAME          Custom table name (default: "media")

  ## Examples

      # Apps with UUID primary keys (default)
      $ mix phx_media_library.install

      # Apps with integer primary keys
      $ mix phx_media_library.install --id-type integer

      # Apps with string/slug primary keys
      $ mix phx_media_library.install --id-type string

  """

  @shortdoc "Installs PhxMediaLibrary in your project"

  use Mix.Task

  import Mix.Generator

  @default_table "media"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          no_migration: :boolean,
          binary_id: :boolean,
          id_type: :string,
          table: :string
        ]
      )

    table = opts[:table] || @default_table

    id_type =
      cond do
        opts[:id_type] -> parse_id_type(opts[:id_type])
        opts[:binary_id] == false -> :integer
        true -> :binary_id
      end

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Installation#{IO.ANSI.reset()}
    ================================
    """)

    unless opts[:no_migration] do
      generate_migration(table, id_type)
    end

    print_configuration_instructions()
    print_usage_instructions()

    Mix.shell().info("""

    #{IO.ANSI.green()}✓ Installation complete!#{IO.ANSI.reset()}

    Next steps:
    1. Review and run the migration: #{IO.ANSI.cyan()}mix ecto.migrate#{IO.ANSI.reset()}
    2. Add the configuration to your config files
    3. Add #{IO.ANSI.cyan()}use PhxMediaLibrary.HasMedia#{IO.ANSI.reset()} to your schemas

    """)
  end

  defp generate_migration(table, id_type) do
    Mix.shell().info("#{IO.ANSI.cyan()}Generating migration...#{IO.ANSI.reset()}")

    _app = Mix.Project.config()[:app]
    migrations_path = Path.join(["priv", "repo", "migrations"])

    File.mkdir_p!(migrations_path)

    timestamp = generate_timestamp()
    filename = "#{timestamp}_create_#{table}_table.exs"
    path = Path.join(migrations_path, filename)

    migration_content = migration_template(table, id_type)

    create_file(path, migration_content)

    Mix.shell().info("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Created #{path}")
  end

  defp migration_template(table, id_type) do
    mediable_id_column_type =
      case id_type do
        :integer -> ":bigint"
        :string -> ":string"
        _ -> ":binary_id"
      end

    """
    defmodule #{inspect(repo_module())}.Migrations.Create#{Macro.camelize(table)}Table do
      use Ecto.Migration

      def change do
        create table(:#{table}, primary_key: [type: :binary_id]) do
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
          add :checksum, :string
          add :checksum_algorithm, :string, default: "sha256"
          add :metadata, :map, default: %{}
          add :deleted_at, :utc_datetime

          # Polymorphic association
          add :mediable_type, :string, null: false
          add :mediable_id, #{mediable_id_column_type}, null: false

          timestamps(type: :utc_datetime)
        end

        create unique_index(:#{table}, [:uuid])
        create index(:#{table}, [:mediable_type, :mediable_id])
        create index(:#{table}, [:collection_name])
        create index(:#{table}, [:mediable_type, :mediable_id, :collection_name])
        create index(:#{table}, [:checksum])
        create index(:#{table}, [:deleted_at])
      end
    end
    """
  end

  defp parse_id_type("integer"), do: :integer
  defp parse_id_type("string"), do: :string
  defp parse_id_type(_), do: :binary_id

  defp print_configuration_instructions do
    _app = Mix.Project.config()[:app]

    Mix.shell().info("""

    #{IO.ANSI.cyan()}Configuration#{IO.ANSI.reset()}
    -------------

    Add the following to your #{IO.ANSI.yellow()}config/config.exs#{IO.ANSI.reset()}:

        config :phx_media_library,
          repo: #{inspect(repo_module())},
          default_disk: :local,
          # mediable_id_type: :binary_id,  # :binary_id (default), :integer, or :string
          disks: [
            local: [
              adapter: PhxMediaLibrary.Storage.Disk,
              root: "priv/static/uploads",
              base_url: "/uploads"
            ]
            # Uncomment for S3 support:
            # s3: [
            #   adapter: PhxMediaLibrary.Storage.S3,
            #   bucket: "my-bucket",
            #   region: "us-east-1"
            # ]
          ]

    If your models use integer primary keys, add:

        config :phx_media_library, mediable_id_type: :integer

    """)
  end

  defp print_usage_instructions do
    Mix.shell().info("""
    #{IO.ANSI.cyan()}Usage#{IO.ANSI.reset()}
    -----

    Add to your Ecto schema:

        defmodule #{inspect(app_module())}.Post do
          use Ecto.Schema
          use PhxMediaLibrary.HasMedia

          schema "posts" do
            field :title, :string
            has_media()
            timestamps()
          end

          def media_collections do
            [
              collection(:images),
              collection(:avatar, single_file: true)
            ]
          end

          def media_conversions do
            [
              conversion(:thumb, width: 150, height: 150, fit: :cover)
            ]
          end
        end

    Then in your code:

        post
        |> PhxMediaLibrary.add("/path/to/image.jpg")
        |> PhxMediaLibrary.to_collection(:images)

    """)
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

  defp app_module do
    app = Mix.Project.config()[:app]
    app |> to_string() |> Macro.camelize() |> String.to_atom()
  end
end
