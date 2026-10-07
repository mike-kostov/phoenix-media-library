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

  alias PhxMediaLibrary.{Config, Health, Media, Pipeline, Telemetry}

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
    if image?(media) do
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
