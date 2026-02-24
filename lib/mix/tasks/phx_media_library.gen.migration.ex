defmodule Mix.Tasks.PhxMediaLibrary.Gen.Migration do
  @moduledoc """
  Generates a new PhxMediaLibrary migration.

  This task is useful for adding new columns or indexes to the media table
  after the initial installation.

  ## Usage

      $ mix phx_media_library.gen.migration add_custom_field

  """

  @shortdoc "Generates a new PhxMediaLibrary migration"

  use Mix.Task

  import Mix.Generator

  @impl Mix.Task
  def run(args) do
    case args do
      [name | _] ->
        generate_migration(name)

      [] ->
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
