defmodule Mix.Tasks.PhxMediaLibrary.Stats do
  @moduledoc """
  Displays storage statistics for media files.

  Queries the media table and prints aggregate counts and sizes grouped by
  collection and by storage disk.

  ## Usage

      $ mix phx_media_library.stats

  ## Options

      --include-trashed   Include soft-deleted records in the report
      --collection NAME   Filter to a specific collection name
      --type TYPE         Filter to a specific mediable_type (e.g. "posts")

  ## Examples

      # Show all stats
      $ mix phx_media_library.stats

      # Include trashed records
      $ mix phx_media_library.stats --include-trashed

      # Filter to a single collection
      $ mix phx_media_library.stats --collection photos

      # Filter to a single model type
      $ mix phx_media_library.stats --type albums

  """

  @shortdoc "Shows storage statistics for media files"

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          include_trashed: :boolean,
          collection: :string,
          type: :string
        ]
      )

    Mix.Task.run("app.start")

    repo = PhxMediaLibrary.Config.repo()
    include_trashed? = Keyword.get(opts, :include_trashed, false)
    collection_filter = opts[:collection]
    type_filter = opts[:type]

    Mix.shell().info("")

    Mix.shell().info(
      "#{IO.ANSI.cyan()}#{IO.ANSI.bright()}PhxMediaLibrary Storage Stats#{IO.ANSI.reset()}"
    )

    Mix.shell().info("==============================")
    Mix.shell().info("")

    base_query = build_base_query(include_trashed?, collection_filter, type_filter)

    collection_rows = fetch_collection_stats(repo, base_query)
    print_collection_table(collection_rows)

    disk_rows = fetch_disk_stats(repo, base_query)
    print_disk_table(disk_rows)
  end

  # ---------------------------------------------------------------------------
  # Query builders
  # ---------------------------------------------------------------------------

  defp build_base_query(include_trashed?, collection_filter, type_filter) do
    query = from(m in PhxMediaLibrary.Media)

    query =
      if not include_trashed? and PhxMediaLibrary.Media.soft_deletes_enabled?() do
        where(query, [m], is_nil(m.deleted_at))
      else
        query
      end

    query =
      if collection_filter do
        where(query, [m], m.collection_name == ^collection_filter)
      else
        query
      end

    if type_filter do
      where(query, [m], m.mediable_type == ^type_filter)
    else
      query
    end
  end

  defp fetch_collection_stats(repo, base_query) do
    base_query
    |> group_by([m], [m.mediable_type, m.collection_name])
    |> select([m], %{
      mediable_type: m.mediable_type,
      collection_name: m.collection_name,
      count: count(m.id),
      total_size: sum(m.size),
      avg_size: avg(m.size)
    })
    |> order_by([m], asc: m.mediable_type, asc: m.collection_name)
    |> repo.all()
  end

  defp fetch_disk_stats(repo, base_query) do
    base_query
    |> group_by([m], m.disk)
    |> select([m], %{
      disk: m.disk,
      count: count(m.id),
      total_size: sum(m.size)
    })
    |> order_by([m], asc: m.disk)
    |> repo.all()
  end

  # ---------------------------------------------------------------------------
  # Table printers
  # ---------------------------------------------------------------------------

  defp print_collection_table([]) do
    Mix.shell().info("#{IO.ANSI.yellow()}No media records found.#{IO.ANSI.reset()}")
    Mix.shell().info("")
  end

  defp print_collection_table(rows) do
    Mix.shell().info("#{IO.ANSI.cyan()}By Collection:#{IO.ANSI.reset()}")

    header =
      "  " <>
        lpad("mediable_type", 18) <>
        "  " <>
        lpad("collection", 14) <>
        "  " <>
        rpad("count", 7) <>
        "  " <>
        rpad("total_size", 12) <>
        "  " <>
        rpad("avg_size", 10)

    sep = "  " <> String.duplicate("─", String.length(header) - 2)

    Mix.shell().info(IO.ANSI.bright() <> header <> IO.ANSI.reset())
    Mix.shell().info(sep)

    Enum.each(rows, fn row ->
      total = to_bytes(row.total_size)
      avg = to_bytes(row.avg_size)

      line =
        "  " <>
          lpad(row.mediable_type, 18) <>
          "  " <>
          lpad(row.collection_name, 14) <>
          "  " <>
          rpad(to_string(row.count), 7) <>
          "  " <>
          rpad(format_size(total), 12) <>
          "  " <>
          rpad(format_size(avg), 10)

      Mix.shell().info(line)
    end)

    Mix.shell().info(sep)

    total_count = Enum.sum(Enum.map(rows, & &1.count))
    total_size = rows |> Enum.map(&to_bytes(&1.total_size)) |> Enum.sum()
    total_avg = if total_count > 0, do: div(total_size, total_count), else: 0

    total_line =
      IO.ANSI.bright() <>
        "  " <>
        lpad("TOTAL", 18) <>
        "  " <>
        lpad("", 14) <>
        "  " <>
        rpad(to_string(total_count), 7) <>
        "  " <>
        rpad(format_size(total_size), 12) <>
        "  " <>
        rpad(format_size(total_avg), 10) <>
        IO.ANSI.reset()

    Mix.shell().info(total_line)
    Mix.shell().info("")
  end

  defp print_disk_table([]) do
    Mix.shell().info("#{IO.ANSI.yellow()}No disk records found.#{IO.ANSI.reset()}")
    Mix.shell().info("")
  end

  defp print_disk_table(rows) do
    Mix.shell().info("#{IO.ANSI.cyan()}By Disk:#{IO.ANSI.reset()}")

    header =
      "  " <>
        lpad("disk", 14) <>
        "  " <>
        rpad("count", 7) <>
        "  " <>
        rpad("total_size", 12)

    sep = "  " <> String.duplicate("─", String.length(header) - 2)

    Mix.shell().info(IO.ANSI.bright() <> header <> IO.ANSI.reset())
    Mix.shell().info(sep)

    Enum.each(rows, fn row ->
      total = to_bytes(row.total_size)

      line =
        "  " <>
          lpad(row.disk, 14) <>
          "  " <>
          rpad(to_string(row.count), 7) <>
          "  " <>
          rpad(format_size(total), 12)

      Mix.shell().info(line)
    end)

    Mix.shell().info(sep)
    Mix.shell().info("")
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  # Left-aligned padding (pad on the right)
  defp lpad(str, width), do: String.pad_trailing(to_string(str || ""), width)

  # Right-aligned padding (pad on the left)
  defp rpad(str, width), do: String.pad_leading(to_string(str || ""), width)

  defp format_size(nil), do: "—"
  defp format_size(0), do: "0 B"

  defp format_size(bytes) when bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 1)} GB"
  end

  defp format_size(bytes) when bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 1)} MB"
  end

  defp format_size(bytes) when bytes >= 1_000 do
    "#{Float.round(bytes / 1_000, 1)} KB"
  end

  defp format_size(bytes), do: "#{bytes} B"

  # Normalise aggregate return values from Ecto.
  # SQLite returns floats for avg/sum; PostgreSQL returns Decimal for avg.
  defp to_bytes(nil), do: 0
  defp to_bytes(n) when is_integer(n), do: n
  defp to_bytes(n) when is_float(n), do: round(n)

  defp to_bytes(d) when is_struct(d, Decimal) do
    d |> Decimal.round(0) |> Decimal.to_integer()
  end
end
