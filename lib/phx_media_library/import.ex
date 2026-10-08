defmodule PhxMediaLibrary.Import do
  @moduledoc """
  Imports many media at once (`PhxMediaLibrary.import_media/2`), for
  migrations from another system, catalogue loads and backfills.

  Each entry's file is checked and stored as an upload would be (type,
  size, pixels, dimensions, file naming), several at a time. The rows are
  then written with `insert_all` in batches, and every derivative (WebP,
  AVIF, the original's variants, conversions, placeholders) is made
  afterwards by one background job per row, which writes its row once.
  `docs/ideas/db-performance.md` measured 4,000 to 6,000 rows/s and 3 to
  5 kB of WAL per row this way, against 20 to 26 kB per upload.

      PhxMediaLibrary.import_media(
        Stream.map(rows, fn row ->
          %{model: product(row), collection: :images, source: {:url, row.image_url}}
        end)
      )
      #=> {:ok, %{inserted: 9_998, failed: [{entry, {:file_too_large, 12_000_000, 10_000_000}}, ...]}}

  Collection limits (`single_file`, `max_files`) hold after each batch:
  the newest media win. Originals are kept even where WebP has
  `keep_original: false`; `mix phx_media_library.doctor --drop-originals`
  removes them after the jobs ran.
  """

  require Logger

  alias PhxMediaLibrary.{Config, Media, MediaAdder, Model, StorageWrapper, Telemetry}

  @default_batch_size 1_000

  # Postgres takes at most 65,535 parameters per statement; a media row has
  # 24 columns, so 2,730 rows. Stay well below.
  @max_batch_size 2_000

  @typedoc """
  An entry: the record and collection to add to and the source, as for
  `PhxMediaLibrary.add/2`; optionally `:filename` (as `using_filename/2`),
  `:custom_properties` and `:disk`.
  """
  @type entry :: %{
          required(:model) => Ecto.Schema.t(),
          required(:collection) => atom(),
          required(:source) => MediaAdder.source(),
          optional(:filename) => String.t(),
          optional(:custom_properties) => map(),
          optional(:disk) => atom()
        }

  @doc """
  Import `entries`, a list or stream. See the module docs.

  ## Options

  - `:batch_size`: rows per `insert_all` (default 1,000, at most 2,000)
  - `:max_concurrency`: files checked and stored at a time (default: the
    number of schedulers)
  - `:disk`: the disk for entries without their own `:disk` (default: each
    collection's)

  Returns `{:ok, %{inserted: count, failed: [{entry, reason}]}}`; a failed
  entry leaves no files behind. Emits `[:phx_media_library, :import, :start
  | :stop]` with the counts.

  ## Examples

      {:ok, %{inserted: 2, failed: []}} =
        PhxMediaLibrary.Import.run([
          %{model: post, collection: :images, source: "/data/a.jpg"},
          %{model: post, collection: :images, source: {:url, "https://example.com/b.jpg"}}
        ])

  """
  @spec run(Enumerable.t(), keyword()) ::
          {:ok, %{inserted: non_neg_integer(), failed: [{entry(), term()}]}}
  def run(entries, opts \\ []) do
    batch_size = opts |> Keyword.get(:batch_size, @default_batch_size) |> min(@max_batch_size)
    concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    Telemetry.span([:phx_media_library, :import], %{}, fn ->
      totals =
        entries
        |> Task.async_stream(&prepare(&1, opts[:disk]),
          max_concurrency: concurrency,
          timeout: :infinity
        )
        |> Stream.map(fn {:ok, prepared} -> prepared end)
        |> Stream.chunk_every(batch_size)
        |> Enum.reduce(%{inserted: 0, failed: []}, &insert_batch/2)
        |> Map.update!(:failed, &Enum.reverse/1)

      {{:ok, totals}, %{inserted: totals.inserted, failed: length(totals.failed)}}
    end)
  end

  # One entry checked and stored, never raising: an import of thousands
  # goes on past a bad file.
  defp prepare(%{model: model, collection: collection, source: source} = entry, disk) do
    adder =
      model
      |> MediaAdder.new(source)
      |> MediaAdder.with_custom_properties(Map.get(entry, :custom_properties, %{}))

    adder =
      if is_binary(entry[:filename]),
        do: MediaAdder.using_filename(adder, entry.filename),
        else: adder

    disk = entry[:disk] || disk
    {entry, MediaAdder.prepare(adder, collection, if(disk, do: [disk: disk], else: []))}
  rescue
    e -> {entry, {:error, {:exception, Exception.message(e)}}}
  end

  defp prepare(entry, _disk), do: {entry, {:error, :invalid_entry}}

  defp insert_batch(batch, totals) do
    failed = for {entry, {:error, reason}} <- batch, do: {entry, reason}
    stored = batch |> Enum.filter(&match?({_entry, {:ok, %Media{}}}, &1)) |> ordered()

    case insert(Enum.map(stored, &elem(&1, 1))) do
      :ok ->
        after_insert(stored)

        %{
          totals
          | inserted: totals.inserted + length(stored),
            failed: Enum.reverse(failed) ++ totals.failed
        }

      {:error, reason} ->
        Enum.each(stored, fn {_entry, media} -> remove_files(media) end)
        rejected = for {entry, _media} <- stored, do: {entry, {:insert_failed, reason}}
        %{totals | failed: Enum.reverse(failed ++ rejected) ++ totals.failed}
    end
  end

  # Files are stored side by side, so positions are given here, in entry
  # order, after what each collection already holds: the last entry is the
  # newest for the collection limits.
  defp ordered(prepared) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {stored, _next} =
      Enum.map_reduce(prepared, %{}, fn {entry, {:ok, media}}, next ->
        key = {entry.model, to_string(entry.collection)}

        position =
          Map.get_lazy(next, key, fn -> Model.next_order(entry.model, entry.collection) end)

        media = %{media | order_column: position, inserted_at: now, updated_at: now}
        {{entry, media}, Map.put(next, key, position + 1)}
      end)

    stored
  end

  defp insert([]), do: :ok

  defp insert(media) do
    rows = Enum.map(media, &(&1 |> Map.from_struct() |> Map.take(Media.__schema__(:fields))))
    Config.repo().insert_all(Media, rows)
    :ok
  rescue
    # The batch's files are removed and its entries reported; the import
    # goes on with the next batch.
    e ->
      Logger.warning("[PhxMediaLibrary] an import batch failed: " <> Exception.message(e))
      {:error, Exception.message(e)}
  end

  # The newest media win the collection limits, then the jobs are queued.
  defp after_insert(stored) do
    stored
    |> Enum.group_by(fn {entry, _media} -> {entry.model, to_string(entry.collection)} end)
    |> Enum.each(fn {{model, collection}, group} ->
      {_entry, newest} = List.last(group)
      Model.enforce_collection_limits(model, collection, newest)
    end)

    Enum.each(stored, fn {entry, media} -> MediaAdder.enqueue_background(entry.model, media) end)
  end

  defp remove_files(media) do
    storage = Config.storage_adapter(media.disk)
    Enum.each(Media.owned_paths(media), &StorageWrapper.delete(storage, &1))
  end
end
