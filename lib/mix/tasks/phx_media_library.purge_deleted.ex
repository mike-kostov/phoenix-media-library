defmodule Mix.Tasks.PhxMediaLibrary.PurgeDeleted do
  @moduledoc """
  Permanently deletes soft-deleted media items that are older than a given age.

  This task removes both the database records and the associated files from
  storage for media items whose `deleted_at` timestamp is older than the
  specified threshold.

  ## Usage

      $ mix phx_media_library.purge_deleted

  By default, purges items soft-deleted more than 30 days ago.

  ## Options

      --days N        Purge items deleted more than N days ago (default: 30)
      --all           Purge all soft-deleted items regardless of age
      --dry-run       Show what would be deleted without actually deleting
      --yes           Skip confirmation prompt

  ## Examples

      # Purge items deleted more than 30 days ago (default)
      $ mix phx_media_library.purge_deleted

      # Purge items deleted more than 7 days ago
      $ mix phx_media_library.purge_deleted --days 7

      # Purge ALL soft-deleted items
      $ mix phx_media_library.purge_deleted --all

      # Preview what would be deleted
      $ mix phx_media_library.purge_deleted --dry-run

  """

  @shortdoc "Permanently deletes old soft-deleted media items"

  use Mix.Task

  alias PhxMediaLibrary.Doctor

  @default_days 30

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          days: :integer,
          all: :boolean,
          dry_run: :boolean,
          yes: :boolean
        ],
        aliases: [
          d: :days,
          n: :dry_run,
          y: :yes
        ]
      )

    Mix.Task.run("app.start")

    purge_opts = [days: Keyword.get(opts, :days, @default_days), all: opts[:all] == true]

    {:ok, %{count: count, examples: examples}} =
      Doctor.purge_deleted([dry_run: true] ++ purge_opts)

    if count == 0 do
      Mix.shell().info(
        "#{IO.ANSI.green()}No soft-deleted media items to purge.#{IO.ANSI.reset()}"
      )

      :ok
    else
      Mix.shell().info("""

      #{IO.ANSI.cyan()}PhxMediaLibrary: Purge Deleted Media#{IO.ANSI.reset()}
      ====================================

      Found #{IO.ANSI.yellow()}#{count}#{IO.ANSI.reset()} soft-deleted media item(s) #{cutoff_label(opts)}.
      """)

      cond do
        opts[:dry_run] ->
          print_items(examples, count)

          Mix.shell().info(
            "\n#{IO.ANSI.yellow()}Dry run, no items were deleted.#{IO.ANSI.reset()}"
          )

          :ok

        opts[:yes] ||
            Mix.shell().yes?("Permanently delete #{count} item(s)? This cannot be undone.") ->
          purge(purge_opts, count)

        true ->
          Mix.shell().info("Aborted.")
          :ok
      end
    end
  end

  defp cutoff_label(opts) do
    if Keyword.get(opts, :all, false) do
      "(all trashed)"
    else
      "deleted more than #{Keyword.get(opts, :days, @default_days)} day(s) ago"
    end
  end

  defp print_items(examples, total) do
    Mix.shell().info(
      "  #{IO.ANSI.cyan()}ID#{IO.ANSI.reset()} | Collection | Filename | Deleted At"
    )

    Mix.shell().info("  " <> String.duplicate("-", 70))

    Enum.each(examples, fn media ->
      deleted = DateTime.to_iso8601(media.deleted_at)

      Mix.shell().info(
        "  #{String.slice(media.id, 0..7)}... | #{media.collection_name} | #{media.file_name} | #{deleted}"
      )
    end)

    if total > length(examples),
      do: Mix.shell().info("  ... and #{total - length(examples)} more")
  end

  defp purge(purge_opts, count) do
    {:ok, %{purged: purged, files_failed: failed}} = Doctor.purge_deleted(purge_opts)

    Mix.shell().info("""

    #{IO.ANSI.green()}✓ Purge complete!#{IO.ANSI.reset()}

      Database records removed: #{purged}
      File cleanups attempted:  #{purged - failed}/#{count}
    """)

    {:ok, purged}
  end
end
