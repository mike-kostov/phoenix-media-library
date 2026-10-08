defmodule PhxMediaLibrary.Doctor.Schedule do
  @moduledoc """
  Runs the doctor once a day, set up from the library's config alone: no
  job to write, nothing to add to your supervision tree or Oban crontab.

      config :phx_media_library, :doctor_schedule,
        enabled: true,
        at: ~T[03:00:00],
        repair: [:missing_placeholder, :missing_conversions]

  Each run checks every media item (`PhxMediaLibrary.Doctor.check/1`),
  repairs what `:repair` lists, and logs a line with the counts. The
  doctor's telemetry events, `[:phx_media_library, :doctor, :check]` and
  `[:phx_media_library, :doctor, :repair]`, carry the same counts for
  alerting.

  ## Options

  - `:enabled`: `false` by default, so no process runs and no job is
    inserted
  - `:at`: the time of day of the run, in UTC (default `~T[03:00:00]`)
  - `:repair`: issue kinds to repair, from `PhxMediaLibrary.Doctor.repairable/0`
    (default `[]`, report only). `:needs_rename` (it changes URLs),
    `:no_files` (it deletes records) and `:original_not_dropped` (it
    deletes originals) need a person deciding, so they are refused here
  - `:runner`: `:oban`, `:internal` or `:auto` (default): Oban when it is
    a dependency, else the internal runner
  - `:oban`: `[name: Oban, queue: :default]`, the Oban instance and the
    queue the job runs in
  - `:batch_size`, `:pause`: read media in batches of 500, pausing 100 ms
    between them, to spare the database (see `PhxMediaLibrary.Doctor`)

  A full check reads every row and, on S3, makes a request per file, so
  pick a quiet hour.

  ## Runners

  The Oban runner inserts one job at startup, scheduled for `at:`; each
  run inserts the next one. The jobs are unique, so several nodes still
  run one job a day, and a new `at:` applies when the app restarts. A
  queue that isn't running on a node is a warning at startup.

  The internal runner is a process in the library's supervision tree. It
  takes a Postgres advisory lock for the run, so only one node runs it.
  If the Repo isn't running at `at:`, it skips the day with a log line.

  An invalid config raises at startup.
  """

  require Logger

  alias PhxMediaLibrary.Doctor

  @refused [:needs_rename, :no_files, :original_not_dropped]

  @defaults [
    enabled: false,
    runner: :auto,
    at: ~T[03:00:00],
    repair: [],
    oban: [name: Oban, queue: :default],
    batch_size: 500,
    pause: 100
  ]

  @typedoc "A validated `:doctor_schedule` config, with `:runner` resolved."
  @type config :: %{
          enabled: boolean(),
          runner: :oban | :internal,
          at: Time.t(),
          repair: [Doctor.kind()],
          oban: keyword(),
          batch_size: pos_integer(),
          pause: non_neg_integer()
        }

  @doc """
  The `:doctor_schedule` config, validated and with its defaults.

  ## Examples

      iex> {:ok, config} = PhxMediaLibrary.Doctor.Schedule.config(enabled: true, at: ~T[04:30:00])
      iex> {config.enabled, config.at, config.repair}
      {true, ~T[04:30:00], []}

      iex> PhxMediaLibrary.Doctor.Schedule.config(repair: [:no_files])
      {:error, "the doctor schedule can't repair [:no_files]; run them by hand"}

  """
  @spec config(keyword()) :: {:ok, config()} | {:error, String.t()}
  def config(opts \\ Application.get_env(:phx_media_library, :doctor_schedule, [])) do
    config = Map.new(Keyword.merge(@defaults, opts))
    oban = Keyword.merge(@defaults[:oban], config.oban)

    with :ok <- known_keys(opts),
         :ok <- check(is_boolean(config.enabled), ":enabled must be true or false"),
         :ok <- check(is_struct(config.at, Time), ":at must be a Time, like ~T[03:00:00]"),
         :ok <- repairs(config.repair),
         :ok <- check(pos_integer?(config.batch_size), ":batch_size must be a positive integer"),
         :ok <- check(is_integer(config.pause) and config.pause >= 0, ":pause must be >= 0"),
         {:ok, runner} <- runner(config.runner) do
      {:ok, %{config | runner: runner, oban: oban}}
    end
  end

  defp known_keys(opts) do
    case Keyword.keys(opts) -- Keyword.keys(@defaults) do
      [] -> :ok
      unknown -> {:error, "unknown :doctor_schedule options #{inspect(unknown)}"}
    end
  end

  defp repairs(repairs) when is_list(repairs) do
    cond do
      (refused = Enum.filter(repairs, &(&1 in @refused))) != [] ->
        {:error, "the doctor schedule can't repair #{inspect(refused)}; run them by hand"}

      (unknown = repairs -- Doctor.repairable()) != [] ->
        {:error, "unknown repairs #{inspect(unknown)}, see PhxMediaLibrary.Doctor.repairable/0"}

      true ->
        :ok
    end
  end

  defp repairs(_), do: {:error, ":repair must be a list of issue kinds"}

  defp runner(:auto), do: {:ok, if(Code.ensure_loaded?(Oban), do: :oban, else: :internal)}
  defp runner(:internal), do: {:ok, :internal}

  defp runner(:oban) do
    if Code.ensure_loaded?(Oban),
      do: {:ok, :oban},
      else: {:error, "runner: :oban needs the :oban dependency"}
  end

  defp runner(other),
    do: {:error, ":runner must be :auto, :oban or :internal, got #{inspect(other)}"}

  defp check(true, _message), do: :ok
  defp check(false, message), do: {:error, message}

  defp pos_integer?(value), do: is_integer(value) and value > 0

  @doc """
  The next run after `now`: today at `at` (UTC) if that is still ahead,
  else tomorrow.

  ## Examples

      iex> PhxMediaLibrary.Doctor.Schedule.next_run(~U[2026-10-08 02:00:00Z], ~T[03:00:00])
      ~U[2026-10-08 03:00:00Z]

      iex> PhxMediaLibrary.Doctor.Schedule.next_run(~U[2026-10-08 03:00:00Z], ~T[03:00:00])
      ~U[2026-10-09 03:00:00Z]

  """
  @spec next_run(DateTime.t(), Time.t()) :: DateTime.t()
  def next_run(%DateTime{} = now, %Time{} = at) do
    today = DateTime.new!(DateTime.to_date(now), at, "Etc/UTC")

    if DateTime.after?(today, now), do: today, else: DateTime.add(today, 1, :day)
  end

  @doc """
  One scheduled run: check every media item, then repair the kinds in
  `config.repair` that the check found. Logs a line with the counts.

  Returns the report and the repair totals (`nil` when nothing was
  repaired).

  ## Examples

      {:ok, config} = PhxMediaLibrary.Doctor.Schedule.config()
      {:ok, %{report: report, repaired: nil}} = PhxMediaLibrary.Doctor.Schedule.run(config)

  """
  @spec run(config()) ::
          {:ok, %{report: Doctor.report(), repaired: map() | nil}} | {:error, term()}
  def run(config) do
    batching = [batch_size: config.batch_size, pause: config.pause]

    with {:ok, report} <- Doctor.check(batching),
         {:ok, repaired} <- repair(report, config.repair, batching) do
      log(report, repaired)
      {:ok, %{report: report, repaired: repaired}}
    end
  end

  defp repair(report, repairs, batching) do
    case Enum.filter(repairs, &Map.has_key?(report.counts, &1)) do
      [] -> {:ok, nil}
      found -> Doctor.repair([repairs: found] ++ batching)
    end
  end

  defp log(report, repaired) do
    level = if report.errors > 0, do: :warning, else: :info

    repaired =
      if repaired, do: ", repaired #{repaired.done}, #{repaired.failed} failed", else: ""

    Logger.log(
      level,
      "[PhxMediaLibrary] scheduled doctor: checked #{report.checked}, " <>
        "issues #{inspect(report.counts)}, errors #{report.errors}#{repaired}"
    )
  end

  @doc false
  # The runner's child for the library's supervision tree, if enabled.
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    case config() do
      {:ok, %{enabled: false}} -> []
      {:ok, %{runner: :internal} = config} -> [{PhxMediaLibrary.Doctor.Scheduler, config: config}]
      {:ok, %{runner: :oban} = config} -> [oban_starter(config)]
      {:error, message} -> raise ArgumentError, "invalid :doctor_schedule config: " <> message
    end
  end

  # Only called when Oban is loaded (runner/1).
  defp oban_starter(config) do
    starter = Module.concat(PhxMediaLibrary.Workers.Doctor, Starter)
    Supervisor.child_spec({Task, fn -> starter.run(config) end}, id: starter, restart: :temporary)
  end
end
