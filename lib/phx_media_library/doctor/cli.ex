defmodule PhxMediaLibrary.Doctor.CLI do
  @moduledoc """
  The doctor's command line: flags, report output and the repair prompt,
  over `PhxMediaLibrary.Doctor`. `mix phx_media_library.doctor` and the
  release command from `mix phx_media_library.gen.release`
  (`bin/media_doctor`) both run it, so they take the same flags; see
  `Mix.Tasks.PhxMediaLibrary.Doctor` for them.

      # In a release (the generated module does this)
      status = PhxMediaLibrary.Doctor.CLI.main(["--regenerate", "--yes"])

  """

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

  @typedoc "How the CLI prints and asks: `info.(line)` and `yes?.(question)`."
  @type io :: %{info: (String.t() -> any()), yes?: (String.t() -> boolean())}

  @doc """
  Run the doctor with command-line `argv`, printing to standard output and
  asking on standard input, and return the exit status: 0 when fine, 1
  when errors were found and `--strict` was given, 2 for invalid
  arguments (the message goes to standard error).

  ## Examples

      PhxMediaLibrary.Doctor.CLI.main(["--model", "products"])
      #=> 0

  """
  @spec main([String.t()]) :: 0 | 1 | 2
  def main(argv) do
    io = %{info: &IO.puts/1, yes?: &yes?/1}

    case run(argv, io) do
      {:ok, status} ->
        status

      {:error, message} ->
        IO.puts(:stderr, message)
        2
    end
  end

  @doc """
  Run the doctor with `argv`, printing and asking through `io`. Returns
  `{:ok, status}` (see `main/1`) or `{:error, message}` for invalid
  arguments.

  ## Examples

      {:ok, 0} = PhxMediaLibrary.Doctor.CLI.run(["--id", id], %{info: &IO.puts/1, yes?: fn _ -> false end})

  """
  @spec run([String.t()], io()) :: {:ok, 0 | 1} | {:error, String.t()}
  def run(argv, io) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    info(io, IO.ANSI.cyan() <> IO.ANSI.bright() <> "PhxMediaLibrary Doctor" <> IO.ANSI.reset())
    info(io, "======================\n")

    with {:ok, report} <- check(opts) do
      if report.checked > 0, do: info(io, "Checking #{report.checked} media item(s)...\n")

      report_issues(io, report, opts)
      report_orphans(io, report)
      report_backlog(io, report)
      run_repairs(io, report, opts)
      print_summary(io, report.errors)

      {:ok, if(opts[:strict] && report.errors > 0, do: 1, else: 0)}
    end
  catch
    {:usage, message} -> {:error, message}
  end

  # No terminal (:eof, an error) means no.
  defp yes?(question) do
    case IO.gets(question <> " [Yn] ") do
      answer when is_binary(answer) -> String.trim(answer) in ["", "y", "Y", "yes", "Yes"]
      _no_input -> false
    end
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
      {:ok, report} -> {:ok, report}
      {:error, {:invalid_id, id}} -> {:error, "--id must be a media UUID, got #{inspect(id)}"}
      {:error, {:not_found, id}} -> {:error, "No media with ID #{id} (or it is in the trash)"}
    end
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  defp report_issues(io, %{counts: counts}, opts) when counts == %{} do
    unless opts[:skip_files], do: info(io, "#{green("✓")} Files, metadata and names: no issues")
  end

  defp report_issues(io, report, _opts) do
    # Errors first, then repairable issues in the order repairs run.
    [:no_files, :checksum_mismatch | Doctor.repairable()]
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(report.counts, &1))
    |> Enum.each(&report_kind(io, &1, report.counts[&1], report.examples[&1]))
  end

  defp report_kind(io, kind, count, examples) do
    mark = if Health.error?(kind), do: red("✗"), else: yellow("!")
    info(io, "#{mark} #{@labels[kind]}: #{count}  (#{@hints[kind]})")
    Enum.each(examples, fn example -> info(io, "    #{describe(example)}#{detail(example)}") end)
    if count > length(examples), do: info(io, "    ... and #{count - length(examples)} more")
  end

  defp report_orphans(_io, %{orphans: nil}), do: :ok

  defp report_orphans(io, %{orphans: orphans, unknown_types: unknown}) do
    Enum.each(unknown, fn type ->
      info(io, "#{yellow("!")} No model found for type '#{type}', skipping its orphan check")
    end)

    if orphans == %{} do
      info(io, "#{green("✓")} Orphaned records: none")
    else
      count = orphans |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      info(io, "#{red("✗")} Media of deleted parent records: #{count} parent(s)")

      Enum.each(orphans, fn {type, ids} ->
        info(io, "    #{type}: #{ids |> Enum.take(5) |> Enum.map_join(", ", &to_string/1)}")
      end)
    end
  end

  defp report_backlog(_io, %{backlog: nil}), do: :ok

  defp report_backlog(io, %{backlog: 0}),
    do: info(io, "#{green("✓")} Soft-delete backlog: none older than 30 days")

  defp report_backlog(io, %{backlog: count}) do
    info(
      io,
      "#{yellow("!")} Soft-delete backlog: #{count} record(s) older than 30 days " <>
        "(mix phx_media_library.purge_deleted)"
    )
  end

  defp print_summary(io, 0), do: info(io, "\n#{green("No errors.")}")
  defp print_summary(io, errors), do: info(io, "\n#{red("#{errors} kind(s) of error found.")}")

  # ---------------------------------------------------------------------------
  # Repairs
  # ---------------------------------------------------------------------------

  defp run_repairs(io, report, opts) do
    repairs = for {flag, kinds} <- @repairs, opts[flag], kind <- kinds, do: kind
    rebuild = if opts[:rebuild], do: rebuild_targets(opts), else: []

    plan =
      repair_plan(report, repairs) ++ for(what <- rebuild, do: {"Rebuild #{what}", report.images})

    plan = Enum.reject(plan, fn {_label, count} -> count == 0 end)

    cond do
      plan == [] ->
        :ok

      opts[:dry_run] ->
        print_plan(io, plan)
        info(io, "\nDry run: nothing changed.")

      true ->
        print_plan(io, plan)

        if opts[:yes] || io.yes?.("\nRun these repairs?"),
          do: execute(io, opts, repairs, rebuild),
          else: info(io, "Repairs skipped.")
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
      throw(
        {:usage,
         "--only accepts conversions, webp, avif, responsive, placeholders; got #{inspect(other)}"}
      )

  defp print_plan(io, plan) do
    info(io, "\nRepair plan:")
    Enum.each(plan, fn {label, count} -> info(io, "  #{label}: #{count}") end)
  end

  defp execute(io, opts, repairs, rebuild) do
    info(io, "")

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
      info(
        io,
        "  #{red("failed")} #{String.slice(id, 0, 8)} #{step_label(step)}: #{inspect(reason)}"
      )
    end)

    info(io, "\n#{green("✓")} #{done} repair(s) done, #{failed} failed")
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

  defp info(io, message), do: io.info.(message)
  defp green(text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp yellow(text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp red(text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
end
