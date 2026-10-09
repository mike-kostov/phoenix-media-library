defmodule PhxMediaLibrary.Doctor do
  @moduledoc """
  Checks the health of stored media and repairs what it can, as plain
  functions: from a scheduled job, an admin page, a release command
  (`mix phx_media_library.gen.release`) or the
  `mix phx_media_library.doctor` task, which only adds flags, output and a
  confirmation prompt on top.

      {:ok, report} = PhxMediaLibrary.Doctor.check(model: "products")
      report.counts   #=> %{missing_conversions: 3, missing_placeholder: 12}
      report.errors   #=> 0

      {:ok, %{done: 15, failed: 0}} =
        PhxMediaLibrary.Doctor.repair(repairs: [:missing_conversions, :missing_placeholder])

  Media is read in batches (`:batch_size`, default 500), so large tables
  don't load into memory at once; `:pause` (milliseconds) waits between
  batches to spare the database. Each run emits a telemetry event with its
  counts: `[:phx_media_library, :doctor, :check]` and
  `[:phx_media_library, :doctor, :repair]`.

  The checks of one media item are `PhxMediaLibrary.Health`'s.
  """

  import Ecto.Query

  alias PhxMediaLibrary.{Config, Health, Media, Pipeline, StorageWrapper, Telemetry}

  @typedoc "An issue kind, as in `PhxMediaLibrary.Health`."
  @type kind :: atom()

  @typedoc """
  The result of `check/1`:

  - `:checked`: media items checked
  - `:images`: of those, images (what `:rebuild` acts on)
  - `:counts`: media items per issue kind
  - `:examples`: up to five per kind, `%{id, mediable_type, collection_name, file_name, detail}`
  - `:orphans`: media of deleted parent records, per type (`nil` when not checked)
  - `:unknown_types`: mediable types with no model to check orphans against
  - `:backlog`: soft-deleted media older than 30 days (`nil` when soft deletes are off or not checked)
  - `:errors`: kinds of error found (no files, checksum mismatches, orphans)
  """
  @type report :: %{
          checked: non_neg_integer(),
          images: non_neg_integer(),
          counts: %{kind() => pos_integer()},
          examples: %{kind() => [map()]},
          orphans: %{String.t() => [term()]} | nil,
          unknown_types: [String.t()],
          backlog: non_neg_integer() | nil,
          errors: non_neg_integer()
        }

  # The order repairs run in: metadata and names first, derivatives next,
  # deleting the original and records last.
  @repair_order [
    :missing_metadata,
    :needs_rename,
    :missing_webp,
    :missing_avif,
    :missing_conversions,
    :missing_responsive,
    :missing_placeholder,
    :outdated_placeholder,
    :missing_blurhash,
    :original_not_dropped,
    :no_files
  ]

  @rebuild_targets [:webp, :avif, :conversions, :responsive, :placeholders]

  @examples 5

  @doc """
  Check media and return a report.

  ## Options

  - `:id`: only this media item
  - `:model`: only this mediable type (`"products"`) or model module name
  - `:collection`, `:disk`: only this collection or disk
  - `:deep`: also verify checksums (reads every file)
  - `:files`: run the per-media checks (default `true`)
  - `:orphans`: check for media of deleted parents (default `true`, `false` with `:id`)
  - `:backlog`: count the soft-delete backlog (default `true`, `false` with `:id`)
  - `:batch_size`, `:pause`: see the module docs

  Returns `{:error, {:invalid_id, id}}` or `{:error, {:not_found, id}}` for
  a bad `:id`.

  ## Examples

      {:ok, report} = PhxMediaLibrary.Doctor.check(collection: "images", deep: true)

  """
  @spec check(keyword()) :: {:ok, report()} | {:error, term()}
  def check(opts \\ []) do
    with {:ok, query} <- media_query(opts) do
      single? = opts[:id] != nil

      files =
        if Keyword.get(opts, :files, true),
          do: check_files(query, opts),
          else: %{checked: 0, images: 0, counts: %{}, examples: %{}}

      {orphans, unknown} =
        if Keyword.get(opts, :orphans, not single?), do: check_orphans(), else: {nil, []}

      backlog = if Keyword.get(opts, :backlog, not single?), do: check_backlog()

      report =
        Map.merge(files, %{
          orphans: orphans,
          unknown_types: unknown,
          backlog: backlog,
          errors: errors(files.counts, orphans)
        })

      Telemetry.event(
        [:phx_media_library, :doctor, :check],
        %{
          checked: report.checked,
          errors: report.errors,
          issues: Enum.sum(Map.values(report.counts))
        },
        %{counts: report.counts, orphans: orphans, backlog: backlog}
      )

      {:ok, report}
    end
  end

  @doc """
  Repair media: the issues listed in `:repairs`, and the derivatives listed
  in `:rebuild` even when present. Media is checked again as it is
  repaired, in batches.

  ## Options

  - `:repairs`: issue kinds to repair, e.g. `[:missing_conversions, :missing_placeholder]`
  - `:rebuild`: derivatives to regenerate for every image: `:webp`, `:avif`,
    `:conversions`, `:responsive`, `:placeholders`
  - `:conversions`: with `:rebuild` of `:conversions`, only these names
  - the filters and batching options of `check/1`

  Returns `{:ok, %{done: n, failed: n, failures: [%{id, step, reason}]}}`
  (up to five failures).

  ## Examples

      {:ok, %{failed: 0}} = PhxMediaLibrary.Doctor.repair(repairs: [:missing_placeholder])
      {:ok, _} = PhxMediaLibrary.Doctor.repair(rebuild: [:webp], collection: "photos")

  """
  @spec repair(keyword()) :: {:ok, map()} | {:error, term()}
  def repair(opts \\ []) do
    repairs = Keyword.get(opts, :repairs, [])
    rebuild = Keyword.get(opts, :rebuild, [])

    with :ok <- valid_rebuild(rebuild),
         {:ok, query} <- media_query(opts) do
      totals =
        query
        |> batches(opts)
        |> Enum.reduce(%{done: 0, failed: 0, failures: []}, fn media, totals ->
          steps = repair_steps(media, repairs, opts) ++ rebuild_steps(media, rebuild, opts)
          run_steps(media, steps, totals)
        end)
        |> Map.update!(:failures, &Enum.reverse/1)

      Telemetry.event(
        [:phx_media_library, :doctor, :repair],
        %{done: totals.done, failed: totals.failed},
        %{repairs: repairs, rebuild: rebuild}
      )

      {:ok, totals}
    end
  end

  @doc """
  The issue kinds `repair/1` can repair, in the order it runs them.

  ## Examples

      iex> :missing_conversions in PhxMediaLibrary.Doctor.repairable()
      true

  """
  @spec repairable() :: [kind()]
  def repairable, do: @repair_order

  @doc """
  Storage statistics: count and sizes per mediable type and collection, and
  per disk.

  ## Options

  - `:include_trashed`: count soft-deleted media too
  - `:collection`, `:type`: only this collection or mediable type

  ## Examples

      {:ok, %{collections: rows, disks: disks}} = PhxMediaLibrary.Doctor.stats(type: "products")
      hd(rows)  #=> %{mediable_type: "products", collection_name: "images", count: 120, total_size: 48_000_000, avg_size: 400_000}

  """
  @spec stats(keyword()) :: {:ok, %{collections: [map()], disks: [map()]}}
  def stats(opts \\ []) do
    base =
      from(m in Media)
      |> stats_trashed(opts[:include_trashed])
      |> stats_filter(:collection_name, opts[:collection])
      |> stats_filter(:mediable_type, opts[:type])

    collections =
      base
      |> group_by([m], [m.mediable_type, m.collection_name])
      |> select([m], %{
        mediable_type: m.mediable_type,
        collection_name: m.collection_name,
        count: count(m.id),
        total_size: sum(m.size),
        avg_size: avg(m.size)
      })
      |> order_by([m], asc: m.mediable_type, asc: m.collection_name)
      |> Config.repo().all()

    disks =
      base
      |> group_by([m], m.disk)
      |> select([m], %{disk: m.disk, count: count(m.id), total_size: sum(m.size)})
      |> order_by([m], asc: m.disk)
      |> Config.repo().all()

    {:ok, %{collections: collections, disks: disks}}
  end

  defp stats_trashed(query, true), do: query

  defp stats_trashed(query, _include?) do
    if Media.soft_deletes_enabled?(), do: where(query, [m], is_nil(m.deleted_at)), else: query
  end

  defp stats_filter(query, _field, nil), do: query
  defp stats_filter(query, field, value), do: where(query, [m], field(m, ^field) == ^value)

  @doc """
  Permanently delete soft-deleted media, files included, in batches.

  ## Options

  - `:days`: only media deleted more than this many days ago (default 30)
  - `:all`: every soft-deleted media item, whatever its age
  - `:dry_run`: count and list (up to 50), delete nothing
  - `:batch_size`: see the module docs

  Returns `{:ok, %{count: n, examples: [media]}}` for a dry run, else
  `{:ok, %{count: n, purged: n, files_failed: n}}`.

  ## Examples

      {:ok, %{count: 12}} = PhxMediaLibrary.Doctor.purge_deleted(days: 7, dry_run: true)
      {:ok, %{purged: 12}} = PhxMediaLibrary.Doctor.purge_deleted(days: 7)

  """
  @spec purge_deleted(keyword()) :: {:ok, map()}
  def purge_deleted(opts \\ []) do
    query = trashed_query(opts)
    count = Config.repo().aggregate(query, :count)

    if opts[:dry_run] do
      examples = query |> order_by([m], asc: m.deleted_at) |> limit(50) |> Config.repo().all()
      {:ok, %{count: count, examples: examples}}
    else
      {purged, failed} =
        query
        |> batches(opts)
        |> Enum.reduce({0, 0}, fn media, {purged, failed} ->
          files_ok? = delete_files_safely(media)
          Config.repo().delete!(media)
          {purged + 1, if(files_ok?, do: failed, else: failed + 1)}
        end)

      {:ok, %{count: count, purged: purged, files_failed: failed}}
    end
  end

  defp trashed_query(opts) do
    query = from(m in Media, where: not is_nil(m.deleted_at))

    if opts[:all] do
      query
    else
      days = Keyword.get(opts, :days, 30)
      cutoff = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.truncate(:second)
      where(query, [m], m.deleted_at < ^cutoff)
    end
  end

  defp delete_files_safely(media) do
    Media.delete_files(media)
    true
  rescue
    _ -> false
  end

  @doc """
  Find files in storage that no media owns, and media none of whose files
  exist, per disk; with `force: true`, delete them. Files are listed on
  local disks only; records are checked on any disk, in batches.

  ## Options

  - `:disk`: only this disk (default: every configured disk)
  - `:files`, `:records`: check files, records (both default `true`)
  - `:force`: delete what was found (default: report only)

  Returns `{:ok, [%{disk: name, files: {:ok, [path]} | {:skipped, reason}, records: [media]}]}`,
  or `{:error, {:unknown_disk, name}}`.

  ## Examples

      {:ok, [%{disk: :local, files: {:ok, orphaned_files}}]} = PhxMediaLibrary.Doctor.clean(disk: "local")

  """
  @spec clean(keyword()) :: {:ok, [map()]} | {:error, term()}
  def clean(opts \\ []) do
    with {:ok, disks} <- clean_disks(opts[:disk]) do
      {:ok, Enum.map(disks, &clean_disk(&1, opts))}
    end
  end

  defp clean_disk(disk, opts) do
    files =
      if Keyword.get(opts, :files, true),
        do: orphaned_files(disk),
        else: {:skipped, :not_requested}

    records = if Keyword.get(opts, :records, true), do: orphaned_records(disk, opts), else: []
    if opts[:force], do: delete_orphans(disk, files, records)
    %{disk: disk, files: files, records: records}
  end

  defp clean_disks(nil),
    do: {:ok, :phx_media_library |> Application.get_env(:disks, []) |> Keyword.keys()}

  defp clean_disks(name) do
    case Enum.find(
           Keyword.keys(Application.get_env(:phx_media_library, :disks, [])),
           &(to_string(&1) == to_string(name))
         ) do
      nil -> {:error, {:unknown_disk, name}}
      disk -> {:ok, [disk]}
    end
  end

  defp orphaned_files(disk) do
    config = Config.disk_config(disk)

    case {config[:adapter], config[:root]} do
      {PhxMediaLibrary.Storage.Disk, root} when is_binary(root) ->
        if File.dir?(root),
          do: {:ok, local_orphans(disk, root)},
          else: {:skipped, {:no_root, root}}

      {adapter, _root} ->
        {:skipped, {:unsupported_adapter, adapter}}
    end
  end

  defp local_orphans(disk, root) do
    stored =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> MapSet.new(&Path.relative_to(&1, root))

    owned =
      from(m in Media, where: m.disk == ^to_string(disk))
      |> batches([])
      |> Enum.reduce(MapSet.new(), fn media, acc -> Enum.into(Media.owned_paths(media), acc) end)

    stored |> MapSet.difference(owned) |> Enum.sort()
  end

  # A record is orphaned only when none of its files exist: WebP-only media
  # (keep_original: false) has no original.
  defp orphaned_records(disk, opts) do
    storage = Config.storage_adapter(disk)

    from(m in Media, where: m.disk == ^to_string(disk))
    |> batches(opts)
    |> Enum.reject(fn media ->
      media |> Media.owned_paths() |> Enum.any?(&StorageWrapper.exists?(storage, &1))
    end)
  end

  defp delete_orphans(disk, files, records) do
    with {:ok, paths} <- files do
      root = Config.disk_config(disk)[:root]
      Enum.each(paths, &File.rm(Path.join(root, &1)))
    end

    Enum.each(records, fn media -> Config.repo().delete!(media) end)
  end

  # -- Loading ---------------------------------------------------------------

  defp media_query(opts) do
    base = from(m in Media) |> Media.exclude_trashed()

    Enum.reduce_while([:id, :model, :collection, :disk], {:ok, base}, fn key, {:ok, query} ->
      case filter(query, key, opts[key]) do
        {:ok, query} -> {:cont, {:ok, query}}
        error -> {:halt, error}
      end
    end)
    |> require_found(opts[:id])
  end

  defp filter(query, _key, nil), do: {:ok, query}

  defp filter(query, :id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, where(query, [m], m.id == ^uuid)}
      :error -> {:error, {:invalid_id, id}}
    end
  end

  defp filter(query, :model, model),
    do: {:ok, where(query, [m], m.mediable_type == ^mediable_type(model))}

  defp filter(query, :collection, name),
    do: {:ok, where(query, [m], m.collection_name == ^to_string(name))}

  defp filter(query, :disk, disk), do: {:ok, where(query, [m], m.disk == ^to_string(disk))}

  defp require_found({:ok, query} = ok, id) when is_binary(id) do
    if Config.repo().exists?(query), do: ok, else: {:error, {:not_found, id}}
  end

  defp require_found(result, _id), do: result

  # "products" or "MyApp.Catalog.Product".
  defp mediable_type(model) when is_atom(model),
    do: PhxMediaLibrary.Model.mediable_type(struct(model))

  defp mediable_type(model) do
    if model =~ ~r/^[A-Z]/ do
      module = Module.concat([model])
      Code.ensure_loaded(module)
      PhxMediaLibrary.Model.mediable_type(struct(module))
    else
      model
    end
  end

  # Keyset pagination on the primary key: each batch is its own short
  # query, so memory stays flat and no transaction stays open.
  defp batches(query, opts) do
    size = Keyword.get(opts, :batch_size, 500)
    pause = Keyword.get(opts, :pause, 0)

    :start
    |> Stream.unfold(&next_batch(query, size, pause, &1))
    |> Stream.flat_map(& &1)
  end

  defp next_batch(_query, _size, _pause, :done), do: nil

  defp next_batch(query, size, pause, after_id) do
    page = query |> after_id(after_id) |> order_by([m], asc: m.id) |> limit(^size)

    case Config.repo().all(page) do
      [] ->
        nil

      media when length(media) < size ->
        {media, :done}

      media ->
        if pause > 0, do: Process.sleep(pause)
        {media, List.last(media).id}
    end
  end

  defp after_id(query, :start), do: query
  defp after_id(query, id), do: where(query, [m], m.id > ^id)

  # -- Checking --------------------------------------------------------------

  defp check_files(query, opts) do
    query
    |> batches(opts)
    |> Enum.reduce(%{checked: 0, images: 0, counts: %{}, examples: %{}}, fn media, acc ->
      issues = Health.check(media, deep: opts[:deep] == true)

      acc
      |> Map.update!(:checked, &(&1 + 1))
      |> Map.update!(:images, &if(image?(media), do: &1 + 1, else: &1))
      |> add_issues(media, issues)
    end)
    |> Map.update!(:examples, fn examples ->
      Map.new(examples, fn {k, v} -> {k, Enum.reverse(v)} end)
    end)
  end

  defp add_issues(acc, media, issues) do
    Enum.reduce(issues, acc, fn issue, acc ->
      kind = kind(issue)

      acc
      |> update_in([:counts, kind], &((&1 || 0) + 1))
      |> update_in([:examples, kind], &add_example(&1 || [], example(media, issue)))
    end)
  end

  defp add_example(examples, example) when length(examples) < @examples, do: [example | examples]
  defp add_example(examples, _example), do: examples

  defp example(media, issue) do
    %{
      id: media.id,
      mediable_type: media.mediable_type,
      collection_name: media.collection_name,
      file_name: media.file_name,
      detail: detail(issue)
    }
  end

  defp detail({_kind, detail}), do: detail
  defp detail(_kind), do: nil

  defp check_orphans do
    %{orphans: orphans, unknown_types: unknown} = Health.orphaned_parents()
    {orphans, unknown}
  end

  defp check_backlog do
    if Media.soft_deletes_enabled?() do
      cutoff = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)
      query = from(m in Media, where: not is_nil(m.deleted_at) and m.deleted_at < ^cutoff)
      Config.repo().aggregate(query, :count)
    end
  end

  defp errors(counts, orphans) do
    file_errors = counts |> Map.keys() |> Enum.count(&Health.error?/1)
    file_errors + if(orphans in [nil, %{}], do: 0, else: 1)
  end

  # -- Repairing -------------------------------------------------------------

  defp valid_rebuild(rebuild) do
    case Enum.reject(rebuild, &(&1 in @rebuild_targets)) do
      [] -> :ok
      [bad | _] -> {:error, {:invalid_rebuild, bad}}
    end
  end

  defp repair_steps(_media, [], _opts), do: []

  defp repair_steps(media, repairs, opts) do
    media
    |> Health.check(deep: opts[:deep] == true)
    |> Enum.filter(&(kind(&1) in repairs))
    |> Enum.sort_by(&Enum.find_index(@repair_order, fn kind -> kind == kind(&1) end))
  end

  defp rebuild_steps(_media, [], _opts), do: []

  defp rebuild_steps(media, rebuild, opts) do
    if PhxMediaLibrary.DocumentRenderer.image_source?(media.mime_type) do
      conversions = Keyword.get(opts, :conversions, [])
      for what <- @rebuild_targets, what in rebuild, do: {:rebuild, what, conversions}
    else
      []
    end
  end

  defp run_steps(media, steps, totals) do
    {_media, totals} =
      Enum.reduce(steps, {media, totals}, fn step, {media, totals} ->
        case run_step(media, step) do
          {:ok, media} ->
            {media, %{totals | done: totals.done + 1}}

          {:error, reason} ->
            failure = %{id: media.id, step: step, reason: reason}
            failures = add_example(totals.failures, failure)
            {media, %{totals | failed: totals.failed + 1, failures: failures}}
        end
      end)

    totals
  end

  # Runs a step and returns the media to continue with (reloaded, since steps
  # update the record), or {:error, reason}.
  defp run_step(media, :no_files) do
    case Health.repair(media, :no_files) do
      :ok -> {:ok, media}
      error -> error
    end
  end

  defp run_step(media, {:rebuild, :conversions, only}),
    do: continue(media, Pipeline.conversions(media, only: only))

  defp run_step(media, {:rebuild, :webp, _}), do: continue(media, Pipeline.webp(media))
  defp run_step(media, {:rebuild, :avif, _}), do: continue(media, Pipeline.avif(media))

  defp run_step(media, {:rebuild, :placeholders, _}),
    do: continue(media, Pipeline.placeholder(media))

  defp run_step(media, {:rebuild, :responsive, _}) do
    of = [nil | Map.keys(media.generated_conversions || %{})]
    continue(media, Pipeline.responsive(media, of: of))
  end

  defp run_step(media, issue), do: continue(media, Health.repair(media, issue))

  defp continue(_media, {:error, _} = error), do: error
  defp continue(media, _ok_or_skip), do: {:ok, Config.repo().reload!(media)}

  defp kind({kind, _detail}), do: kind
  defp kind(kind), do: kind

  defp image?(media), do: String.starts_with?(media.mime_type || "", "image/")
end
