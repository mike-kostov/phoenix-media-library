if Code.ensure_loaded?(Oban) do
  defmodule PhxMediaLibrary.Workers.Doctor do
    @moduledoc """
    The Oban job of the scheduled doctor (`PhxMediaLibrary.Doctor.Schedule`).
    You don't insert it yourself: with `runner: :oban` the library inserts
    the first job at startup, and each run inserts the next.

    A run that finds issues still succeeds; the job fails only when the
    doctor can't run. It isn't retried: the next day's job is already
    scheduled.
    """

    use Oban.Worker, max_attempts: 1

    alias PhxMediaLibrary.Doctor.Schedule

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      case Schedule.config() do
        {:ok, %{enabled: true, runner: :oban} = config} ->
          # The next day first, so a failed run doesn't end the schedule.
          with {:ok, _job} <- schedule_next(config, DateTime.utc_now(), :running),
               {:ok, _result} <- Schedule.run(config),
               do: :ok

        # Switched off (or to the internal runner) since this job was
        # inserted: stop here, without a next one.
        _disabled ->
          {:cancel, :schedule_disabled}
      end
    end

    @doc """
    Insert the next run, at `config.at` after `now`.

    One job is scheduled at a time, across nodes. At startup (`:startup`)
    a scheduled job takes the current `at:`, and an executing one is left
    to schedule the next; from a run (`:running`) the executing job is
    this one, so it doesn't count.

    ## Examples

        {:ok, config} = PhxMediaLibrary.Doctor.Schedule.config(enabled: true)
        {:ok, _job} = PhxMediaLibrary.Workers.Doctor.schedule_next(config, DateTime.utc_now(), :startup)

    """
    @spec schedule_next(Schedule.config(), DateTime.t(), :startup | :running) ::
            {:ok, Oban.Job.t()} | {:error, term()}
    def schedule_next(config, now, from) do
      states =
        if from == :startup,
          do: [:available, :scheduled, :executing, :retryable],
          else: [:available, :scheduled, :retryable]

      %{}
      |> new(
        queue: config.oban[:queue],
        scheduled_at: Schedule.next_run(now, config.at),
        unique: [period: :infinity, states: states],
        replace: [scheduled: [:scheduled_at]]
      )
      |> then(&Oban.insert(config.oban[:name], &1))
    end
  end

  defmodule PhxMediaLibrary.Workers.Doctor.Starter do
    @moduledoc false
    # Runs once at startup, in a Task: the library starts before the app's
    # Oban, so it waits for the instance, warns about a missing queue, and
    # inserts the first job.

    require Logger

    alias PhxMediaLibrary.Workers.Doctor

    @doc false
    def run(config, opts \\ []) do
      name = config.oban[:name]

      if wait_for(name, Keyword.get(opts, :attempts, 60), Keyword.get(opts, :interval, 1_000)) do
        warn_missing_queue(name, config.oban[:queue])

        with {:error, reason} = error <-
               Doctor.schedule_next(config, DateTime.utc_now(), :startup) do
          Logger.warning("[PhxMediaLibrary] the doctor schedule isn't set: #{inspect(reason)}")
          error
        end
      else
        Logger.warning(
          "[PhxMediaLibrary] the doctor schedule isn't set: Oban instance #{inspect(name)} " <>
            "isn't running. Start it, set its name in :doctor_schedule's :oban, " <>
            "or use runner: :internal."
        )

        :not_started
      end
    end

    defp wait_for(name, attempts, interval) do
      cond do
        Oban.whereis(name) ->
          true

        attempts <= 1 ->
          false

        true ->
          Process.sleep(interval)
          wait_for(name, attempts - 1, interval)
      end
    end

    defp warn_missing_queue(name, queue) do
      unless Keyword.has_key?(Oban.config(name).queues, queue) do
        Logger.warning(
          "[PhxMediaLibrary] the scheduled doctor runs in Oban queue #{inspect(queue)}, " <>
            "which isn't running on this node"
        )
      end
    end
  end
end
