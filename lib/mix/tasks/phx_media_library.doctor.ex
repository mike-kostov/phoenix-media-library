defmodule Mix.Tasks.PhxMediaLibrary.Doctor do
  @moduledoc """
  Runs health checks on the media library and reports issues.

  Performs four checks:

  1. **File existence** — verifies every local-disk media file is present on
     disk (skipped for remote adapters such as S3).
  2. **Broken conversions** — verifies that every recorded conversion file
     exists on disk.
  3. **Orphaned records** — detects media records whose parent model no longer
     exists in the database (uses `PhxMediaLibrary.ModelRegistry`).
  4. **Soft-delete backlog** — warns when there are trashed records older than
     30 days (only when soft-deletes are enabled).

  ## Usage

      $ mix phx_media_library.doctor

  ## Options

      --skip-files    Skip file existence and broken-conversion checks
      --skip-orphans  Skip orphaned record detection
      --fix           Permanently delete broken/missing media (with prompt)

  ## Examples

      # Full health check
      $ mix phx_media_library.doctor

      # Skip file checks (useful when files are on S3)
      $ mix phx_media_library.doctor --skip-files

      # Automatically clean up broken media after confirmation
      $ mix phx_media_library.doctor --fix

  """

  @shortdoc "Runs health checks on media files and records"

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          skip_files: :boolean,
          skip_orphans: :boolean,
          fix: :boolean
        ]
      )

    Mix.Task.run("app.start")
    ensure_all_modules_loaded()

    repo = PhxMediaLibrary.Config.repo()

    Mix.shell().info("")

    Mix.shell().info(
      IO.ANSI.cyan() <> IO.ANSI.bright() <> "PhxMediaLibrary Doctor" <> IO.ANSI.reset()
    )

    Mix.shell().info("======================")
    Mix.shell().info("")
    Mix.shell().info("Running health checks...")
    Mix.shell().info("")

    state = %{errors: 0, warnings: 0, passed: 0, fix_items: [], repo: repo, opts: opts}

    state =
      if opts[:skip_files] do
        state
      else
        state
        |> run_missing_files_check()
        |> run_broken_conversions_check()
      end

    state =
      if opts[:skip_orphans] do
        state
      else
        run_orphan_check(state)
      end

    state = run_soft_delete_backlog_check(state)

    print_summary(state)

    if opts[:fix] && state.fix_items != [] do
      do_fix(state)
    end
  end

  # ---------------------------------------------------------------------------
  # Module loading helper
  # ---------------------------------------------------------------------------

  # Force-load every module from every currently running application so that
  # ModelRegistry's :code.all_loaded() scan can find Ecto schema modules that
  # haven't been called yet at task startup (e.g. GalleryApp.Galleries.Album).
  defp ensure_all_modules_loaded do
    for {app, _desc, _vsn} <- :application.loaded_applications() do
      case :application.get_key(app, :modules) do
        {:ok, modules} -> Enum.each(modules, &Code.ensure_loaded/1)
        _ -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Check 1 — Missing files
  # ---------------------------------------------------------------------------

  defp run_missing_files_check(state) do
    {total_checked, missing} =
      Enum.reduce(get_local_disks(), {0, []}, fn disk_name, {checked, issues} ->
        {count, new_missing} = check_disk_for_missing(disk_name, state.repo)
        {checked + count, issues ++ new_missing}
      end)

    if missing == [] do
      Mix.shell().info(
        "#{IO.ANSI.green()}✓#{IO.ANSI.reset()} File existence check " <>
          "(#{total_checked} files checked, 0 missing)"
      )

      %{state | passed: state.passed + 1}
    else
      report_missing_files(missing, total_checked)
      new_fix_items = Enum.map(missing, fn {media, _path} -> media end)

      %{
        state
        | errors: state.errors + 1,
          fix_items: Enum.uniq_by(state.fix_items ++ new_fix_items, & &1.id)
      }
    end
  end

  defp check_disk_for_missing(disk_name, repo) do
    disk_str = to_string(disk_name)

    media_items =
      from(m in PhxMediaLibrary.Media, where: m.disk == ^disk_str)
      |> repo.all()

    missing = Enum.flat_map(media_items, &find_missing_file/1)
    {length(media_items), missing}
  end

  defp find_missing_file(media) do
    case PhxMediaLibrary.PathGenerator.full_path(media, nil) do
      nil -> []
      path -> if File.exists?(path), do: [], else: [{media, path}]
    end
  end

  defp report_missing_files(missing, total_checked) do
    Mix.shell().info(
      "#{IO.ANSI.red()}✗#{IO.ANSI.reset()} File existence check " <>
        "(#{total_checked} checked, #{length(missing)} missing):"
    )

    Enum.each(missing, fn {media, path} ->
      id_short = String.slice(media.id, 0, 8)
      Mix.shell().info("    - #{path} (media id: #{id_short}...)")
    end)
  end

  # ---------------------------------------------------------------------------
  # Check 2 — Broken conversions
  # ---------------------------------------------------------------------------

  defp run_broken_conversions_check(state) do
    issues =
      get_local_disks()
      |> Enum.flat_map(&check_disk_for_broken_conversions(&1, state.repo))

    if issues == [] do
      Mix.shell().info(
        "#{IO.ANSI.green()}✓#{IO.ANSI.reset()} Broken conversions (0 issues found)"
      )

      %{state | passed: state.passed + 1}
    else
      report_broken_conversions(issues)
      new_fix_items = issues |> Enum.map(fn {media, _, _} -> media end) |> Enum.uniq_by(& &1.id)

      %{
        state
        | errors: state.errors + 1,
          fix_items: Enum.uniq_by(state.fix_items ++ new_fix_items, & &1.id)
      }
    end
  end

  defp check_disk_for_broken_conversions(disk_name, repo) do
    disk_str = to_string(disk_name)

    from(m in PhxMediaLibrary.Media, where: m.disk == ^disk_str)
    |> repo.all()
    |> Enum.filter(&(map_size(&1.generated_conversions) > 0))
    |> Enum.flat_map(&find_broken_conversions_for_media/1)
  end

  defp find_broken_conversions_for_media(media) do
    media.generated_conversions
    |> Map.keys()
    |> Enum.flat_map(&check_conversion_file(media, &1))
  end

  defp check_conversion_file(media, conversion) do
    case PhxMediaLibrary.PathGenerator.full_path(media, conversion) do
      nil -> []
      path -> if File.exists?(path), do: [], else: [{media, conversion, path}]
    end
  end

  defp report_broken_conversions(issues) do
    Mix.shell().info(
      "#{IO.ANSI.red()}✗#{IO.ANSI.reset()} Broken conversions (#{length(issues)} issues found):"
    )

    Enum.each(issues, fn {media, conversion, path} ->
      id_short = String.slice(media.id, 0, 8)
      Mix.shell().info("    - #{path} (media #{id_short}..., conversion: #{conversion})")
    end)
  end

  # ---------------------------------------------------------------------------
  # Check 3 — Orphaned records
  # ---------------------------------------------------------------------------

  defp run_orphan_check(state) do
    mediable_types =
      from(m in PhxMediaLibrary.Media, distinct: true, select: m.mediable_type)
      |> state.repo.all()

    {total_orphans, skipped_types} =
      Enum.reduce(mediable_types, {0, []}, fn mediable_type, acc ->
        accumulate_orphan_result(state.repo, mediable_type, acc)
      end)

    Enum.each(skipped_types, &report_skipped_type/1)

    if total_orphans == 0 do
      Mix.shell().info(
        "#{IO.ANSI.green()}✓#{IO.ANSI.reset()} Orphaned records (no orphans found)"
      )

      %{state | passed: state.passed + 1}
    else
      Mix.shell().info(
        "#{IO.ANSI.red()}✗#{IO.ANSI.reset()} Orphaned records (#{total_orphans} found)"
      )

      %{state | errors: state.errors + 1}
    end
  end

  defp accumulate_orphan_result(repo, mediable_type, {orphan_count, skipped}) do
    case PhxMediaLibrary.ModelRegistry.find_model_module(mediable_type) do
      :error ->
        {orphan_count, [mediable_type | skipped]}

      {:ok, module} ->
        count_orphans_for_module(repo, mediable_type, module, orphan_count, skipped)
    end
  end

  defp count_orphans_for_module(repo, mediable_type, module, orphan_count, skipped) do
    if function_exported?(module, :__schema__, 1) do
      orphan_ids = find_orphan_ids(repo, mediable_type, module)
      {orphan_count + length(orphan_ids), skipped}
    else
      {orphan_count, [mediable_type | skipped]}
    end
  end

  defp report_skipped_type(type) do
    Mix.shell().info(
      "  #{IO.ANSI.yellow()}⚠#{IO.ANSI.reset()} No module found for type '#{type}'" <>
        " — skipping orphan check for this type"
    )
  end

  @spec find_orphan_ids(Ecto.Repo.t(), String.t(), module()) :: [term()]
  defp find_orphan_ids(repo, mediable_type, module) do
    mediable_ids =
      from(m in PhxMediaLibrary.Media,
        where: m.mediable_type == ^mediable_type,
        select: m.mediable_id
      )
      |> repo.all()
      |> MapSet.new()

    if MapSet.size(mediable_ids) == 0 do
      []
    else
      table_source = module.__schema__(:source)
      pk_field = module.__schema__(:primary_key) |> hd()

      existing_ids =
        from(s in {table_source, module})
        |> select([s], field(s, ^pk_field))
        |> repo.all()
        |> MapSet.new()

      mediable_ids |> MapSet.difference(existing_ids) |> MapSet.to_list()
    end
  end

  # ---------------------------------------------------------------------------
  # Check 4 — Soft-delete backlog
  # ---------------------------------------------------------------------------

  defp run_soft_delete_backlog_check(state) do
    if PhxMediaLibrary.Media.soft_deletes_enabled?() do
      check_soft_delete_backlog(state)
    else
      state
    end
  end

  defp check_soft_delete_backlog(state) do
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.truncate(:second)

    count =
      from(m in PhxMediaLibrary.Media,
        where: not is_nil(m.deleted_at),
        where: m.deleted_at < ^cutoff
      )
      |> state.repo.aggregate(:count)

    if count > 0 do
      Mix.shell().info(
        "#{IO.ANSI.yellow()}⚠#{IO.ANSI.reset()} Soft-delete backlog: #{count} record(s) older" <>
          " than 30 days. Run: mix phx_media_library.purge_deleted"
      )

      %{state | warnings: state.warnings + 1}
    else
      Mix.shell().info(
        "#{IO.ANSI.green()}✓#{IO.ANSI.reset()} Soft-delete backlog (none older than 30 days)"
      )

      %{state | passed: state.passed + 1}
    end
  end

  # ---------------------------------------------------------------------------
  # Summary + fix
  # ---------------------------------------------------------------------------

  defp print_summary(state) do
    error_color = if state.errors > 0, do: IO.ANSI.red(), else: ""
    warn_color = if state.warnings > 0, do: IO.ANSI.yellow(), else: ""
    pass_color = IO.ANSI.green()

    parts = [
      "#{error_color}#{state.errors} error(s)#{IO.ANSI.reset()}",
      "#{warn_color}#{state.warnings} warning(s)#{IO.ANSI.reset()}",
      "#{pass_color}#{state.passed} passed#{IO.ANSI.reset()}"
    ]

    Mix.shell().info("")
    Mix.shell().info("Summary: #{Enum.join(parts, ", ")}")
  end

  defp do_fix(state) do
    count = length(state.fix_items)
    prompt = "Permanently delete #{count} broken/missing media record(s)? This cannot be undone."

    Mix.shell().info("")

    if Mix.shell().yes?(prompt) do
      {ok_count, err_count} = Enum.reduce(state.fix_items, {0, 0}, &delete_one_media/2)
      Mix.shell().info("")

      Mix.shell().info(
        "#{IO.ANSI.green()}✓ Fix complete!#{IO.ANSI.reset()}" <>
          " Deleted: #{ok_count}, Failed: #{err_count}"
      )
    else
      Mix.shell().info("Fix aborted.")
    end
  end

  defp delete_one_media(media, {ok, err}) do
    id_short = String.slice(media.id, 0, 8)

    case PhxMediaLibrary.Media.permanently_delete(media) do
      :ok ->
        Mix.shell().info(
          "  #{IO.ANSI.green()}Deleted#{IO.ANSI.reset()} #{id_short}... (#{media.file_name})"
        )

        {ok + 1, err}

      {:error, reason} ->
        Mix.shell().error("  Failed to delete #{id_short}...: #{inspect(reason)}")
        {ok, err + 1}
    end
  end

  # ---------------------------------------------------------------------------
  # Disk helpers
  # ---------------------------------------------------------------------------

  defp get_local_disks do
    Application.get_env(:phx_media_library, :disks, [])
    |> Keyword.keys()
    |> Enum.filter(&local_disk?/1)
  end

  defp local_disk?(disk_name) do
    config = PhxMediaLibrary.Config.disk_config(disk_name)
    adapter = Keyword.get(config, :adapter)
    Code.ensure_loaded(adapter)
    function_exported?(adapter, :path, 2)
  rescue
    _ -> false
  end
end
