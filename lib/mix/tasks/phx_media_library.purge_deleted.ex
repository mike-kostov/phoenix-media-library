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

  import Ecto.Query

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

    repo = Application.fetch_env!(:phx_media_library, :repo)
    dry_run? = Keyword.get(opts, :dry_run, false)
    skip_confirm? = Keyword.get(opts, :yes, false)

    cutoff = resolve_cutoff(opts)
    query = build_query(cutoff)
    count = repo.aggregate(query, :count)

    if count == 0 do
      Mix.shell().info(
        "#{IO.ANSI.green()}No soft-deleted media items to purge.#{IO.ANSI.reset()}"
      )

      :ok
    else
      label = cutoff_label(opts)

      Mix.shell().info("""

      #{IO.ANSI.cyan()}PhxMediaLibrary — Purge Deleted Media#{IO.ANSI.reset()}
      ======================================

      Found #{IO.ANSI.yellow()}#{count}#{IO.ANSI.reset()} soft-deleted media item(s) #{label}.
      """)

      if dry_run? do
        print_items(repo, query)

        Mix.shell().info(
          "\n#{IO.ANSI.yellow()}Dry run — no items were deleted.#{IO.ANSI.reset()}"
        )

        :ok
      else
        maybe_purge(repo, query, count, skip_confirm?)
      end
    end
  end

  defp maybe_purge(repo, query, count, skip_confirm?) do
    confirmed? =
      skip_confirm? ||
        Mix.shell().yes?("Permanently delete #{count} item(s)? This cannot be undone.")

    if confirmed? do
      purge(repo, query, count)
    else
      Mix.shell().info("Aborted.")
      :ok
    end
  end

  defp resolve_cutoff(opts) do
    if Keyword.get(opts, :all, false) do
      nil
    else
      days = Keyword.get(opts, :days, @default_days)
      DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.truncate(:second)
    end
  end

  defp build_query(nil) do
    from(m in PhxMediaLibrary.Media,
      where: not is_nil(m.deleted_at)
    )
  end

  defp build_query(%DateTime{} = cutoff) do
    from(m in PhxMediaLibrary.Media,
      where: not is_nil(m.deleted_at),
      where: m.deleted_at < ^cutoff
    )
  end

  defp cutoff_label(opts) do
    if Keyword.get(opts, :all, false) do
      "(all trashed)"
    else
      "deleted more than #{Keyword.get(opts, :days, @default_days)} day(s) ago"
    end
  end

  defp print_items(repo, query) do
    items =
      query
      |> order_by([m], asc: m.deleted_at)
      |> limit(50)
      |> repo.all()

    Mix.shell().info(
      "  #{IO.ANSI.cyan()}ID#{IO.ANSI.reset()} | Collection | Filename | Deleted At"
    )

    Mix.shell().info("  " <> String.duplicate("-", 70))

    Enum.each(items, fn media ->
      deleted = media.deleted_at |> DateTime.to_iso8601()

      Mix.shell().info(
        "  #{String.slice(media.id, 0..7)}... | #{media.collection_name} | #{media.file_name} | #{deleted}"
      )
    end)

    total = repo.aggregate(query, :count)

    if total > 50 do
      Mix.shell().info("  ... and #{total - 50} more")
    end
  end

  defp purge(repo, query, count) do
    # Fetch all items so we can delete their files
    items = repo.all(query)

    # Delete files from storage
    deleted_files =
      Enum.reduce(items, 0, fn media, acc ->
        case delete_files(media) do
          :ok -> acc + 1
          _ -> acc
        end
      end)

    # Delete database records
    {db_count, _} =
      query
      |> exclude(:order_by)
      |> repo.delete_all()

    Mix.shell().info("""

    #{IO.ANSI.green()}✓ Purge complete!#{IO.ANSI.reset()}

      Database records removed: #{db_count}
      File cleanups attempted:  #{deleted_files}/#{count}
    """)

    {:ok, db_count}
  end

  defp delete_files(%PhxMediaLibrary.Media{disk: disk} = media) do
    storage = PhxMediaLibrary.Config.storage_adapter(disk)

    # Delete original
    original_path = PhxMediaLibrary.PathGenerator.relative_path(media, nil)
    PhxMediaLibrary.StorageWrapper.delete(storage, original_path)

    # Delete conversions
    media.generated_conversions
    |> Map.keys()
    |> Enum.each(fn conversion ->
      conversion_path = PhxMediaLibrary.PathGenerator.relative_path(media, conversion)
      PhxMediaLibrary.StorageWrapper.delete(storage, conversion_path)
    end)

    # Delete responsive image variants
    media.responsive_images
    |> Map.values()
    |> List.flatten()
    |> Enum.each(fn
      %{"path" => path} -> PhxMediaLibrary.StorageWrapper.delete(storage, path)
      _ -> :ok
    end)

    :ok
  rescue
    _ -> :error
  end
end
