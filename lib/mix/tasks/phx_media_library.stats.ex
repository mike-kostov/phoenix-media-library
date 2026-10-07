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

    Mix.shell().info("")

    Mix.shell().info(
      "#{IO.ANSI.cyan()}#{IO.ANSI.bright()}PhxMediaLibrary Storage Stats#{IO.ANSI.reset()}"
    )

    Mix.shell().info("==============================")
    Mix.shell().info("")

    {:ok, %{collections: collections, disks: disks}} =
      PhxMediaLibrary.Doctor.stats(
        include_trashed: Keyword.get(opts, :include_trashed, false),
        collection: opts[:collection],
        type: opts[:type]
      )

    print_collection_table(collections)
    print_disk_table(disks)
  end

  # ---------------------------------------------------------------------------
  # Output
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
  defp rpad(str, width), do: String.pad_leading(str, width)

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
