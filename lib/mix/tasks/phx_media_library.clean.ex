defmodule Mix.Tasks.PhxMediaLibrary.Clean do
  @moduledoc """
  Cleans up orphaned media files.

  This task finds and optionally removes:
  - Files in storage that don't have corresponding database records
  - Database records that don't have corresponding files in storage

  ## Usage

      # Show orphaned files (dry run)
      $ mix phx_media_library.clean

      # Actually delete orphaned files
      $ mix phx_media_library.clean --force

      # Only check specific disk
      $ mix phx_media_library.clean --disk local

      # Only clean orphaned files (not database records)
      $ mix phx_media_library.clean --files-only

      # Only clean orphaned database records (not files)
      $ mix phx_media_library.clean --records-only

  ## Options

      --force         Actually delete orphaned items (default: dry run)
      --disk          Only check this disk
      --files-only    Only clean orphaned files
      --records-only  Only clean orphaned database records

  """

  @shortdoc "Cleans up orphaned media files"

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          force: :boolean,
          disk: :string,
          files_only: :boolean,
          records_only: :boolean
        ]
      )

    # Start the application
    Mix.Task.run("app.start")

    force? = opts[:force] || false
    disk = opts[:disk]
    files_only? = opts[:files_only] || false
    records_only? = opts[:records_only] || false

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Clean#{IO.ANSI.reset()}
    =====================
    """)

    unless force? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN - no changes will be made#{IO.ANSI.reset()}")
      Mix.shell().info("Use --force to actually delete orphaned items\n")
    end

    disks = get_disks(disk)

    unless records_only? do
      clean_orphaned_files(disks, force?)
    end

    unless files_only? do
      clean_orphaned_records(disks, force?)
    end

    Mix.shell().info("\n#{IO.ANSI.green()}✓ Cleanup complete!#{IO.ANSI.reset()}")
  end

  defp get_disks(nil) do
    Application.get_env(:phx_media_library, :disks, [])
    |> Keyword.keys()
  end

  defp get_disks(disk) do
    [String.to_atom(disk)]
  end

  defp clean_orphaned_files(disks, force?) do
    Mix.shell().info("\n#{IO.ANSI.cyan()}Checking for orphaned files...#{IO.ANSI.reset()}\n")

    repo = PhxMediaLibrary.Config.repo()

    Enum.each(disks, fn disk_name ->
      Mix.shell().info("Disk: #{disk_name}")

      config = PhxMediaLibrary.Config.disk_config(disk_name)
      adapter = config[:adapter]

      case adapter do
        PhxMediaLibrary.Storage.Disk ->
          clean_local_disk(disk_name, config, repo, force?)

        PhxMediaLibrary.Storage.S3 ->
          clean_s3_disk(disk_name, config, repo, force?)

        _ ->
          Mix.shell().info("  Skipping (unsupported adapter)")
      end
    end)
  end

  defp clean_local_disk(disk_name, config, repo, force?) do
    root = config[:root]

    unless File.exists?(root) do
      Mix.shell().info("  Storage root doesn't exist: #{root}")
      return(:ok)
    end

    # Get all files in storage
    storage_files =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> MapSet.new()

    # Get all expected paths from database
    db_paths =
      from(m in PhxMediaLibrary.Media, where: m.disk == ^to_string(disk_name))
      |> repo.all()
      |> Enum.flat_map(&get_all_paths/1)
      |> MapSet.new()

    # Find orphaned files
    orphaned = MapSet.difference(storage_files, db_paths)

    if MapSet.size(orphaned) == 0 do
      Mix.shell().info("  #{IO.ANSI.green()}No orphaned files found#{IO.ANSI.reset()}")
    else
      Mix.shell().info("  Found #{MapSet.size(orphaned)} orphaned file(s):")

      Enum.each(orphaned, fn path ->
        full_path = Path.join(root, path)

        if force? do
          File.rm!(full_path)
          Mix.shell().info("    #{IO.ANSI.red()}Deleted#{IO.ANSI.reset()}: #{path}")
        else
          Mix.shell().info("    #{path}")
        end
      end)
    end
  end

  defp clean_s3_disk(_disk_name, _config, _repo, _force?) do
    Mix.shell().info("  S3 cleanup not yet implemented")
    # TODO: Implement S3 cleanup using ExAws.S3.list_objects_v2
  end

  defp clean_orphaned_records(disks, force?) do
    Mix.shell().info("\n#{IO.ANSI.cyan()}Checking for orphaned database records...#{IO.ANSI.reset()}\n")

    repo = PhxMediaLibrary.Config.repo()

    Enum.each(disks, fn disk_name ->
      Mix.shell().info("Disk: #{disk_name}")

      config = PhxMediaLibrary.Config.disk_config(disk_name)
      storage = PhxMediaLibrary.Config.storage_adapter(disk_name)

      # Get all media records for this disk
      media_items =
        from(m in PhxMediaLibrary.Media, where: m.disk == ^to_string(disk_name))
        |> repo.all()

      orphaned =
        Enum.filter(media_items, fn media ->
          path = PhxMediaLibrary.PathGenerator.relative_path(media, nil)
          not storage.exists?(path)
        end)

      if orphaned == [] do
        Mix.shell().info("  #{IO.ANSI.green()}No orphaned records found#{IO.ANSI.reset()}")
      else
        Mix.shell().info("  Found #{length(orphaned)} orphaned record(s):")

        Enum.each(orphaned, fn media ->
          if force? do
            repo.delete!(media)
            Mix.shell().info("    #{IO.ANSI.red()}Deleted#{IO.ANSI.reset()}: #{media.file_name} (#{media.id})")
          else
            Mix.shell().info("    #{media.file_name} (#{media.id})")
          end
        end)
      end
    end)
  end

  defp get_all_paths(media) do
    # Original file path
    original = PhxMediaLibrary.PathGenerator.relative_path(media, nil)

    # Conversion paths
    conversion_paths =
      media.generated_conversions
      |> Map.keys()
      |> Enum.map(&PhxMediaLibrary.PathGenerator.relative_path(media, &1))

    # Responsive image paths
    responsive_paths =
      media.responsive_images
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1["path"])
      |> Enum.filter(& &1)

    [original | conversion_paths ++ responsive_paths]
  end

  defp return(value), do: value
end
