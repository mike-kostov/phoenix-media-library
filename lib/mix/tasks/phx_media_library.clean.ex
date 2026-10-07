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

    Mix.Task.run("app.start")
    force? = opts[:force] || false

    Mix.shell().info("""

    #{IO.ANSI.cyan()}PhxMediaLibrary Clean#{IO.ANSI.reset()}
    =====================
    """)

    unless force? do
      Mix.shell().info("#{IO.ANSI.yellow()}DRY RUN - no changes will be made#{IO.ANSI.reset()}")
      Mix.shell().info("Use --force to actually delete orphaned items\n")
    end

    clean_opts = [
      disk: opts[:disk],
      files: !opts[:records_only],
      records: !opts[:files_only],
      force: force?
    ]

    case PhxMediaLibrary.Doctor.clean(clean_opts) do
      {:ok, results} ->
        unless opts[:records_only], do: report_files(results, force?)
        unless opts[:files_only], do: report_records(results, force?)
        Mix.shell().info("\n#{IO.ANSI.green()}✓ Cleanup complete!#{IO.ANSI.reset()}")

      {:error, {:unknown_disk, name}} ->
        Mix.raise("Unknown disk: #{name}")
    end
  end

  defp report_files(results, force?) do
    Mix.shell().info("\n#{IO.ANSI.cyan()}Checking for orphaned files...#{IO.ANSI.reset()}\n")

    Enum.each(results, fn %{disk: disk, files: files} ->
      Mix.shell().info("Disk: #{disk}")

      case files do
        {:ok, []} ->
          Mix.shell().info("  #{IO.ANSI.green()}No orphaned files found#{IO.ANSI.reset()}")

        {:ok, paths} ->
          Mix.shell().info("  Found #{length(paths)} orphaned file(s):")
          Enum.each(paths, &Mix.shell().info("    #{deleted(force?)}#{&1}"))

        {:skipped, {:no_root, root}} ->
          Mix.shell().info("  Storage root doesn't exist: #{root}")

        {:skipped, _reason} ->
          Mix.shell().info("  Skipping (files are listed on local disks only)")
      end
    end)
  end

  defp report_records(results, force?) do
    Mix.shell().info(
      "\n#{IO.ANSI.cyan()}Checking for orphaned database records...#{IO.ANSI.reset()}\n"
    )

    Enum.each(results, fn %{disk: disk, records: records} ->
      Mix.shell().info("Disk: #{disk}")
      report_disk_records(records, force?)
    end)
  end

  defp report_disk_records([], _force?),
    do: Mix.shell().info("  #{IO.ANSI.green()}No orphaned records found#{IO.ANSI.reset()}")

  defp report_disk_records(records, force?) do
    Mix.shell().info("  Found #{length(records)} orphaned record(s):")

    Enum.each(records, fn media ->
      Mix.shell().info("    #{deleted(force?)}#{media.file_name} (#{media.id})")
    end)
  end

  defp deleted(true), do: "#{IO.ANSI.red()}Deleted#{IO.ANSI.reset()}: "
  defp deleted(false), do: ""
end
