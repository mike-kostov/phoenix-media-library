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

  The task is a thin wrapper: the checks and repairs are
  `PhxMediaLibrary.Doctor.check/1` and `repair/1`, which also run without
  Mix (in a release, a scheduled job, an admin page).

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

  alias PhxMediaLibrary.{Doctor, Health}

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

    report = check(opts)
    if report.checked > 0, do: info("Checking #{report.checked} media item(s)...\n")

    report_issues(report, opts)
    report_orphans(report)
    report_backlog(report)

    run_repairs(report, opts)
    print_summary(report.errors)

    if opts[:strict] && report.errors > 0, do: exit({:shutdown, 1})
  end

  # ---------------------------------------------------------------------------
  # Checking: PhxMediaLibrary.Doctor does the work
  # ---------------------------------------------------------------------------

  defp check(opts) do
    check_opts =
      [
        id: opts[:id],
        model: opts[:model],
        collection: opts[:collection],
        disk: opts[:disk],
        deep: opts[:deep] == true,
        files: !opts[:skip_files],
        orphans: !opts[:skip_orphans] and is_nil(opts[:id]),
        backlog: is_nil(opts[:id])
      ]

    case Doctor.check(check_opts) do
      {:ok, report} -> report
      {:error, {:invalid_id, id}} -> Mix.raise("--id must be a media UUID, got #{inspect(id)}")
      {:error, {:not_found, id}} -> Mix.raise("No media with ID #{id} (or it is in the trash)")
    end
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  defp report_issues(%{counts: counts}, opts) when counts == %{} do
    unless opts[:skip_files], do: info("#{green("✓")} Files, metadata and names: no issues")
  end

  defp report_issues(report, _opts) do
    # Errors first, then repairable issues in the order repairs run.
    [:no_files, :checksum_mismatch | Doctor.repairable()]
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(report.counts, &1))
    |> Enum.each(&report_kind(&1, report.counts[&1], report.examples[&1]))
  end

  defp report_kind(kind, count, examples) do
    mark = if Health.error?(kind), do: red("✗"), else: yellow("!")
    info("#{mark} #{@labels[kind]}: #{count}  (#{@hints[kind]})")
    Enum.each(examples, fn example -> info("    #{describe(example)}#{detail(example)}") end)
    if count > length(examples), do: info("    ... and #{count - length(examples)} more")
  end

  defp report_orphans(%{orphans: nil}), do: :ok

  defp report_orphans(%{orphans: orphans, unknown_types: unknown}) do
    Enum.each(unknown, fn type ->
      info("#{yellow("!")} No model found for type '#{type}', skipping its orphan check")
    end)

    if orphans == %{} do
      info("#{green("✓")} Orphaned records: none")
    else
      count = orphans |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      info("#{red("✗")} Media of deleted parent records: #{count} parent(s)")

      Enum.each(orphans, fn {type, ids} ->
        info("    #{type}: #{ids |> Enum.take(5) |> Enum.map_join(", ", &to_string/1)}")
      end)
    end
  end

  defp report_backlog(%{backlog: nil}), do: :ok

  defp report_backlog(%{backlog: 0}),
    do: info("#{green("✓")} Soft-delete backlog: none older than 30 days")

  defp report_backlog(%{backlog: count}) do
    info(
      "#{yellow("!")} Soft-delete backlog: #{count} record(s) older than 30 days " <>
        "(mix phx_media_library.purge_deleted)"
    )
  end

  defp print_summary(0), do: info("\n#{green("No errors.")}")
  defp print_summary(errors), do: info("\n#{red("#{errors} kind(s) of error found.")}")

  # ---------------------------------------------------------------------------
  # Repairs
  # ---------------------------------------------------------------------------

  defp run_repairs(report, opts) do
    repairs = for {flag, kinds} <- @repairs, opts[flag], kind <- kinds, do: kind
    rebuild = if opts[:rebuild], do: rebuild_targets(opts), else: []

    plan =
      repair_plan(report, repairs) ++ for(what <- rebuild, do: {"Rebuild #{what}", report.images})

    plan = Enum.reject(plan, fn {_label, count} -> count == 0 end)

    cond do
      plan == [] ->
        :ok

      opts[:dry_run] ->
        print_plan(plan)
        info("\nDry run: nothing changed.")

      true ->
        print_plan(plan)

        if opts[:yes] || Mix.shell().yes?("\nRun these repairs?"),
          do: execute(opts, repairs, rebuild),
          else: info("Repairs skipped.")
    end
  end

  defp repair_plan(report, repairs) do
    for kind <- Doctor.repairable(),
        kind in repairs,
        count = report.counts[kind],
        count,
        do: {"Repair: #{@labels[kind]}", count}
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

  defp print_plan(plan) do
    info("\nRepair plan:")
    Enum.each(plan, fn {label, count} -> info("  #{label}: #{count}") end)
  end

  defp execute(opts, repairs, rebuild) do
    info("")

    {:ok, %{done: done, failed: failed, failures: failures}} =
      Doctor.repair(
        id: opts[:id],
        model: opts[:model],
        collection: opts[:collection],
        disk: opts[:disk],
        deep: opts[:deep] == true,
        repairs: repairs,
        rebuild: rebuild,
        conversions: Keyword.get_values(opts, :conversion)
      )

    Enum.each(failures, fn %{id: id, step: step, reason: reason} ->
      info("  #{red("failed")} #{String.slice(id, 0, 8)} #{step_label(step)}: #{inspect(reason)}")
    end)

    info("\n#{green("✓")} #{done} repair(s) done, #{failed} failed")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp step_label({:rebuild, what, _}), do: "Rebuild #{what}"
  defp step_label({kind, _detail}), do: "Repair: #{@labels[kind]}"
  defp step_label(kind), do: "Repair: #{@labels[kind]}"

  defp detail(%{detail: names}) when is_list(names), do: ": #{Enum.join(names, ", ")}"
  defp detail(_example), do: ""

  defp describe(example) do
    "#{String.slice(example.id, 0, 8)} #{example.mediable_type}/#{example.collection_name} " <>
      example.file_name
  end

  defp info(message), do: Mix.shell().info(message)
  defp green(text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp yellow(text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp red(text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
end
