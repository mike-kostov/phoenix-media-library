defmodule Mix.Tasks.PhxMediaLibrary.Doctor do
  @moduledoc """
  Checks the health of stored media and repairs what it can.

  Without options it only reports. Repairs are opt-in, show their plan and
  ask before running (`--yes` skips the question). Each repair runs the same
  `PhxMediaLibrary.Pipeline` step an upload runs, so repaired media matches
  newly uploaded media. Works with any storage adapter (on S3 every file
  check is a request, so large libraries take a while).

  ## What it checks

    * **Files.** Media with no files left (error); missing conversions,
      WebP, AVIF, responsive variants or placeholders (repairable).
    * **Metadata.** Images without dimensions, e.g. from the EXIF-date bug
      before 0.8.4 (repairable).
    * **Names.** Files not stored under their collection's `file_naming`,
      e.g. uploaded before 0.9 (repairable).
    * **Originals.** Originals still present where the collection says
      WebP `keep_original: false` (repairable).
    * **Integrity.** Checksum mismatches, with `--deep` (error).
    * **Records.** Media whose parent record no longer exists, and the
      soft-delete backlog.

  The checks find what is missing or outdated, not what was made with
  other settings: after changing a collection's conversion, WebP, AVIF,
  responsive or placeholder settings, run `--rebuild` for it.

  See `PhxMediaLibrary.Health` for the checks as functions.

  ## Usage

      # Report only
      $ mix phx_media_library.doctor

      # Fill in missing conversions, WebP, AVIF, variants and placeholders
      $ mix phx_media_library.doctor --regenerate

      # Rename pre-0.9 files and fill in lost metadata, for one model
      $ mix phx_media_library.doctor --model products --rename --reextract

      # Rebuild every WebP after changing its quality
      $ mix phx_media_library.doctor --rebuild --only webp

      # Check and repair one media item
      $ mix phx_media_library.doctor --id 8f2c4d1e-… --regenerate

  ## Repairs

      --regenerate      Create missing conversions, WebP, AVIF, responsive
                        variants and placeholders
      --reextract       Extract missing metadata (dimensions, EXIF)
      --rename          Move files to their collection's file_naming
                        (URLs change; old links will 404)
      --drop-originals  Delete originals where keep_original: false
      --fix             Permanently delete media with no files left
      --rebuild         Regenerate derivatives even when present (after
                        changing conversion, WebP, AVIF, responsive or
                        placeholder settings)
        --only          With --rebuild: conversions, webp, avif, responsive
                        and/or placeholders
                        (comma-separated; default all)
        --conversion    With --rebuild: only this conversion (repeatable)

  ## Filters and other options

      --id              Only this media item (skips the orphan and backlog
                        reports, which cover all media)
      --model           Only this model: mediable type ("products") or
                        module (MyApp.Catalog.Product)
      --collection      Only this collection
      --disk            Only this disk
      --deep            Also verify checksums (reads every file)
      --skip-files      Skip the per-media checks
      --skip-orphans    Skip the orphaned-records check
      --dry-run         Show the repair plan without asking or running it
      --yes             Run repairs without asking
      --strict          Exit with status 1 when errors are found
                        (for scheduled jobs and CI)

  """

  @shortdoc "Checks media health and repairs problems"

  use Mix.Task

  import Ecto.Query

  alias PhxMediaLibrary.{Config, Health, Media, Pipeline}

  @switches [
    regenerate: :boolean,
    reextract: :boolean,
    rename: :boolean,
    drop_originals: :boolean,
    fix: :boolean,
    rebuild: :boolean,
    only: :string,
    conversion: :keep,
    id: :string,
    model: :string,
    collection: :string,
    disk: :string,
    deep: :boolean,
    skip_files: :boolean,
    skip_orphans: :boolean,
    dry_run: :boolean,
    yes: :boolean,
    strict: :boolean
  ]

  # Issue kinds each repair flag covers, in the order repairs run: metadata
  # and names first, derivatives next, deleting the original last.
  @repairs [
    reextract: [:missing_metadata],
    rename: [:needs_rename],
    regenerate: [
      :missing_webp,
      :missing_avif,
      :missing_conversions,
      :missing_responsive,
      :missing_placeholder,
      :outdated_placeholder
    ],
    drop_originals: [:original_not_dropped],
    fix: [:no_files]
  ]

  @labels %{
    no_files: "Media with no files left",
    checksum_mismatch: "Checksum mismatch",
    missing_conversions: "Missing conversions",
    missing_webp: "Missing WebP",
    missing_avif: "Missing AVIF",
    missing_placeholder: "Missing placeholder",
    outdated_placeholder: "Outdated placeholder (0.8 JPEG, or on a transparent image)",
    missing_responsive: "Missing responsive variants",
    missing_metadata: "Missing metadata",
    needs_rename: "Not named by file_naming",
    original_not_dropped: "Original kept despite keep_original: false"
  }

  @hints %{
    no_files: "--fix deletes these records",
    checksum_mismatch: "restore these files from a backup",
    missing_conversions: "--regenerate",
    missing_webp: "--regenerate",
    missing_avif: "--regenerate",
    missing_placeholder: "--regenerate",
    outdated_placeholder: "--regenerate",
    missing_responsive: "--regenerate",
    missing_metadata: "--reextract",
    needs_rename: "--rename",
    original_not_dropped: "--drop-originals"
  }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.start")

    info(IO.ANSI.cyan() <> IO.ANSI.bright() <> "PhxMediaLibrary Doctor" <> IO.ANSI.reset())
    info("======================\n")

    media = load_media(opts)
    results = if opts[:skip_files], do: [], else: check_all(media, opts)

    errors =
      if opts[:id],
        do: report_issues(results),
        else: report_issues(results) + report_orphans(opts) + report_backlog()

    run_repairs(results, media, opts)
    print_summary(errors)

    if opts[:strict] && errors > 0, do: exit({:shutdown, 1})
  end

  # ---------------------------------------------------------------------------
  # Checking
  # ---------------------------------------------------------------------------

  defp load_media(opts) do
    query = from(m in Media, order_by: [asc: m.inserted_at, asc: m.id])

    media =
      [:id, :model, :collection, :disk]
      |> Enum.reduce(query, fn key, query -> filter(query, key, opts[key]) end)
      |> Media.exclude_trashed()
      |> Config.repo().all()

    if opts[:id] && media == [],
      do: Mix.raise("No media with ID #{opts[:id]} (or it is in the trash)"),
      else: media
  end

  defp filter(query, _key, nil), do: query

  defp filter(query, :id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> where(query, [m], m.id == ^uuid)
      :error -> Mix.raise("--id must be a media UUID, got #{inspect(id)}")
    end
  end

  defp filter(query, :model, model),
    do: where(query, [m], m.mediable_type == ^mediable_type(model))

  defp filter(query, :collection, name), do: where(query, [m], m.collection_name == ^name)
  defp filter(query, :disk, disk), do: where(query, [m], m.disk == ^disk)

  # "products" or "MyApp.Catalog.Product".
  defp mediable_type(model) do
    if model =~ ~r/^[A-Z]/ do
      module = Module.concat([model])
      Code.ensure_loaded(module)
      PhxMediaLibrary.Model.mediable_type(struct(module))
    else
      model
    end
  end

  defp check_all(media, opts) do
    info("Checking #{length(media)} media item(s)...\n")

    media
    |> Enum.map(&{&1, Health.check(&1, deep: opts[:deep])})
    |> Enum.reject(fn {_media, issues} -> issues == [] end)
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  # Returns the number of error kinds reported.
  defp report_issues(results) do
    by_kind =
      for {media, issues} <- results, issue <- issues, reduce: %{} do
        acc -> Map.update(acc, kind(issue), [{media, issue}], &[{media, issue} | &1])
      end

    if by_kind == %{}, do: info("#{green("✓")} Files, metadata and names: no issues")

    # Errors first, then repairable issues in the order repairs run.
    [:no_files, :checksum_mismatch | @repairs |> Keyword.values() |> List.flatten()]
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(by_kind, &1))
    |> Enum.map(fn kind -> report_kind(kind, Enum.reverse(by_kind[kind])) end)
    |> Enum.sum()
  end

  defp report_kind(kind, items) do
    error? = Health.error?(kind)
    mark = if error?, do: red("✗"), else: yellow("!")
    info("#{mark} #{@labels[kind]}: #{length(items)}  (#{@hints[kind]})")

    items
    |> Enum.take(5)
    |> Enum.each(fn {media, issue} -> info("    #{describe(media)}#{detail(issue)}") end)

    if length(items) > 5, do: info("    ... and #{length(items) - 5} more")
    if error?, do: 1, else: 0
  end

  defp report_orphans(opts) do
    if opts[:skip_orphans] do
      0
    else
      %{orphans: orphans, unknown_types: unknown} = Health.orphaned_parents()

      Enum.each(unknown, fn type ->
        info("#{yellow("!")} No model found for type '#{type}', skipping its orphan check")
      end)

      report_orphan_count(orphans)
    end
  end

  defp report_orphan_count(orphans) when orphans == %{} do
    info("#{green("✓")} Orphaned records: none")
    0
  end

  defp report_orphan_count(orphans) do
    count = orphans |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    info("#{red("✗")} Media of deleted parent records: #{count} parent(s)")

    Enum.each(orphans, fn {type, ids} ->
      info("    #{type}: #{ids |> Enum.take(5) |> Enum.map_join(", ", &to_string/1)}")
    end)

    1
  end

  defp report_backlog do
    if Media.soft_deletes_enabled?() do
      cutoff = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)
      query = from(m in Media, where: not is_nil(m.deleted_at) and m.deleted_at < ^cutoff)

      case Config.repo().aggregate(query, :count) do
        0 ->
          info("#{green("✓")} Soft-delete backlog: none older than 30 days")

        count ->
          info(
            "#{yellow("!")} Soft-delete backlog: #{count} record(s) older than 30 days " <>
              "(mix phx_media_library.purge_deleted)"
          )
      end
    end

    0
  end

  defp print_summary(0), do: info("\n#{green("No errors.")}")
  defp print_summary(errors), do: info("\n#{red("#{errors} kind(s) of error found.")}")

  # ---------------------------------------------------------------------------
  # Repairs
  # ---------------------------------------------------------------------------

  defp run_repairs(results, media, opts) do
    plan = repair_plan(results, opts) ++ rebuild_plan(media, opts)

    cond do
      plan == [] ->
        :ok

      opts[:dry_run] ->
        print_plan(plan)
        info("\nDry run: nothing changed.")

      true ->
        print_plan(plan)

        if opts[:yes] || Mix.shell().yes?("\nRun these repairs?"),
          do: execute(plan),
          else: info("Repairs skipped.")
    end
  end

  # [{media, [step]}], where a step is an issue to repair or
  # {:rebuild, what, conversion_names}.
  defp repair_plan(results, opts) do
    selected = for {flag, kinds} <- @repairs, opts[flag], kind <- kinds, do: kind
    order = @repairs |> Keyword.values() |> List.flatten()

    for {media, issues} <- results,
        steps = issues |> Enum.filter(&(kind(&1) in selected)) |> sort_by_kind(order),
        steps != [],
        do: {media, steps}
  end

  defp rebuild_plan(media, opts) do
    if opts[:rebuild] do
      conversions = Keyword.get_values(opts, :conversion)
      steps = for what <- rebuild_targets(opts), do: {:rebuild, what, conversions}
      for m <- media, String.starts_with?(m.mime_type || "", "image/"), do: {m, steps}
    else
      []
    end
  end

  defp rebuild_targets(opts) do
    case opts[:only] do
      nil -> [:webp, :avif, :conversions, :responsive, :placeholders]
      only -> only |> String.split(",", trim: true) |> Enum.map(&rebuild_target/1)
    end
  end

  defp rebuild_target("conversions"), do: :conversions
  defp rebuild_target("webp"), do: :webp
  defp rebuild_target("avif"), do: :avif
  defp rebuild_target("placeholders"), do: :placeholders
  defp rebuild_target("responsive"), do: :responsive

  defp rebuild_target(other),
    do:
      Mix.raise(
        "--only accepts conversions, webp, avif, responsive, placeholders; got #{inspect(other)}"
      )

  defp sort_by_kind(issues, order),
    do: Enum.sort_by(issues, &Enum.find_index(order, fn kind -> kind == kind(&1) end))

  defp print_plan(plan) do
    counts =
      for {_media, steps} <- plan, step <- steps, reduce: %{} do
        acc -> Map.update(acc, step_label(step), 1, &(&1 + 1))
      end

    info("\nRepair plan:")
    Enum.each(counts, fn {label, count} -> info("  #{label}: #{count}") end)
  end

  defp execute(plan) do
    info("")
    {ok, failed} = Enum.reduce(plan, {0, 0}, &execute_media/2)
    info("\n#{green("✓")} #{ok} repair(s) done, #{failed} failed")
  end

  defp execute_media({media, steps}, totals) do
    {_media, totals} =
      Enum.reduce(steps, {media, totals}, fn step, {media, {ok, failed}} ->
        case run_step(media, step) do
          {:ok, media} ->
            {media, {ok + 1, failed}}

          {:error, reason} ->
            info("  #{red("failed")} #{describe(media)} #{step_label(step)}: #{inspect(reason)}")
            {media, {ok, failed + 1}}
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp kind({kind, _detail}), do: kind
  defp kind(kind), do: kind

  defp step_label({:rebuild, what, _}), do: "Rebuild #{what}"
  defp step_label(issue), do: "Repair: #{@labels[kind(issue)]}"

  defp detail({:missing_conversions, names}), do: ": #{Enum.join(names, ", ")}"
  defp detail(_issue), do: ""

  defp describe(media) do
    "#{String.slice(media.id, 0, 8)} #{media.mediable_type}/#{media.collection_name} " <>
      media.file_name
  end

  defp info(message), do: Mix.shell().info(message)
  defp green(text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp yellow(text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp red(text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
end
