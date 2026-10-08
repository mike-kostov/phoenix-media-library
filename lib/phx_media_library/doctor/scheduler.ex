defmodule PhxMediaLibrary.Doctor.Scheduler do
  @moduledoc false
  # The internal runner of PhxMediaLibrary.Doctor.Schedule: waits for the
  # next `at:`, runs the doctor under a Postgres advisory lock, and waits
  # again.

  use GenServer

  require Logger

  alias PhxMediaLibrary.{Config, Doctor.Schedule}

  @lock_key :erlang.phash2("phx_media_library:doctor_schedule")

  # Nodes' clocks differ a little: holding the lock for at least this long
  # keeps a node whose timer fires late from running the day again.
  @min_hold :timer.minutes(1)

  @doc false
  # Options: `:config` (from Schedule.config/0), and for tests `:clock`
  # (a function returning the current DateTime), `:hold` and `:name`.
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      config: Keyword.fetch!(opts, :config),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      hold: Keyword.get(opts, :hold, @min_hold)
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:run, state) do
    run_once(state.config, hold: state.hold)
    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    now = state.clock.()
    wait = DateTime.diff(Schedule.next_run(now, state.config.at), now, :millisecond)
    Process.send_after(self(), :run, wait)
    state
  end

  @doc false
  # One run, unless the Repo is down or another node holds the lock.
  @spec run_once(Schedule.config(), keyword()) :: {:ok, map()} | {:error, term()} | :skipped
  def run_once(config, opts \\ []) do
    repo = Config.repo()

    if GenServer.whereis(repo.get_dynamic_repo()) do
      repo.checkout(fn -> with_lock(repo, Keyword.get(opts, :hold, @min_hold), config) end)
    else
      Logger.warning("[PhxMediaLibrary] scheduled doctor skipped: #{inspect(repo)} isn't running")
      :skipped
    end
  end

  # A session lock on the checked-out connection; the run's queries use the
  # same connection and no transaction, so it holds no snapshot open.
  defp with_lock(repo, hold, config) do
    case repo.query("SELECT pg_try_advisory_lock($1)", [@lock_key]) do
      {:ok, %{rows: [[true]]}} ->
        started = System.monotonic_time(:millisecond)

        try do
          Schedule.run(config)
        after
          Process.sleep(max(0, hold - (System.monotonic_time(:millisecond) - started)))
          repo.query("SELECT pg_advisory_unlock($1)", [@lock_key])
        end

      {:ok, %{rows: [[false]]}} ->
        Logger.info("[PhxMediaLibrary] scheduled doctor skipped: another node is running it")
        :skipped

      {:error, reason} ->
        Logger.warning("[PhxMediaLibrary] scheduled doctor skipped: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
