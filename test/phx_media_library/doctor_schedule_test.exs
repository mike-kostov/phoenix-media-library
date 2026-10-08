defmodule PhxMediaLibrary.Doctor.ScheduleTest do
  use PhxMediaLibrary.DataCase, async: false

  import ExUnit.CaptureLog
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Config, Media, PathGenerator, StorageWrapper}
  alias PhxMediaLibrary.Doctor.{Schedule, Scheduler}
  alias PhxMediaLibrary.TestRepo, as: Repo
  alias PhxMediaLibrary.Workers.Doctor, as: Worker
  alias PhxMediaLibrary.Workers.Doctor.Starter

  @moduletag :db

  doctest Schedule

  defmodule NotStartedRepo do
    def get_dynamic_repo, do: __MODULE__
  end

  setup do
    previous = Application.fetch_env(:phx_media_library, :doctor_schedule)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :doctor_schedule, value)
        :error -> Application.delete_env(:phx_media_library, :doctor_schedule)
      end
    end)
  end

  defp config(opts) do
    {:ok, config} = Schedule.config(opts)
    config
  end

  # The test config logs warnings and up; these logs are info.
  defp info_log(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: level)
    end
  end

  defp attach(event) do
    test = self()
    id = "schedule-test-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, event, fn _, m, _, _ -> send(test, {:event, event, m}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # An image whose thumb conversion is gone: a :missing_conversions issue.
  defp image_missing_thumb do
    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(:images, disk: :local)

    media = Repo.reload!(media)
    on_exit(fn -> if m = Repo.get(Media, media.id), do: Media.delete_files(m) end)

    StorageWrapper.delete(
      Config.storage_adapter(:local),
      PathGenerator.relative_path(media, :thumb)
    )

    media
  end

  describe "config/1" do
    test "is off by default: no process, no job" do
      Application.delete_env(:phx_media_library, :doctor_schedule)
      assert {:ok, %{enabled: false, repair: []}} = Schedule.config()
      assert Schedule.children() == []
    end

    test "refuses repairs that need a person, and unknown ones" do
      assert {:error, message} = Schedule.config(repair: [:missing_placeholder, :needs_rename])
      assert message =~ ":needs_rename"
      assert {:error, _} = Schedule.config(repair: [:original_not_dropped])
      assert {:error, message} = Schedule.config(repair: [:typo])
      assert message =~ ":typo"
    end

    test "rejects unknown options and bad values" do
      assert {:error, message} = Schedule.config(every: :hour)
      assert message =~ ":every"
      assert {:error, _} = Schedule.config(at: "03:00")
      assert {:error, _} = Schedule.config(runner: :cron)
      assert {:error, _} = Schedule.config(enabled: "yes")
    end

    test "an invalid config raises at startup" do
      Application.put_env(:phx_media_library, :doctor_schedule,
        enabled: true,
        repair: [:no_files]
      )

      assert_raise ArgumentError, ~r/:no_files/, fn -> Schedule.children() end
    end

    test ":auto picks Oban when it is loaded" do
      assert {:ok, %{runner: :oban}} = Schedule.config(runner: :auto)
      assert {:ok, %{runner: :internal}} = Schedule.config(runner: :internal)
    end
  end

  test "next_run/2 rolls over months and years" do
    assert Schedule.next_run(~U[2026-12-31 23:00:00Z], ~T[03:00:00]) == ~U[2027-01-01 03:00:00Z]
  end

  describe "run/1" do
    test "reports, and emits the doctor's telemetry" do
      media = image_missing_thumb()
      attach([:phx_media_library, :doctor, :check])

      log =
        info_log(fn ->
          assert {:ok, %{report: report, repaired: nil}} = Schedule.run(config(pause: 0))
          assert report.counts[:missing_conversions] >= 1
        end)

      assert log =~ "scheduled doctor: checked"
      assert_received {:event, [:phx_media_library, :doctor, :check], %{issues: issues}}
      assert issues >= 1

      # Report only: nothing repaired.
      refute StorageWrapper.exists?(
               Config.storage_adapter(:local),
               PathGenerator.relative_path(media, :thumb)
             )
    end

    test "repairs only the listed kinds" do
      media = image_missing_thumb()

      assert {:ok, %{repaired: %{done: done}}} =
               Schedule.run(config(repair: [:missing_conversions], pause: 0))

      assert done >= 1

      assert StorageWrapper.exists?(
               Config.storage_adapter(:local),
               PathGenerator.relative_path(Repo.reload!(media), :thumb)
             )
    end
  end

  describe "internal runner" do
    test "runs at `at:`" do
      attach([:phx_media_library, :doctor, :check])
      at = ~T[03:00:00]
      now = ~D[2026-10-08] |> DateTime.new!(at, "Etc/UTC") |> DateTime.add(-50, :millisecond)

      start_supervised!(
        {Scheduler,
         config: config(runner: :internal, at: at, pause: 0),
         clock: fn -> now end,
         hold: 0,
         name: nil}
      )

      assert_receive {:event, [:phx_media_library, :doctor, :check], _}, 2_000
    end

    test "skips the run while another node holds the lock" do
      conn = start_supervised!({Postgrex, Keyword.delete(Repo.config(), :pool)})
      key = :erlang.phash2("phx_media_library:doctor_schedule")
      Postgrex.query!(conn, "SELECT pg_advisory_lock($1)", [key])

      log =
        info_log(fn ->
          assert Scheduler.run_once(config(runner: :internal), hold: 0) == :skipped
        end)

      assert log =~ "another node"
    end

    test "skips the day when the Repo isn't running" do
      previous = Application.get_env(:phx_media_library, :repo)
      Application.put_env(:phx_media_library, :repo, NotStartedRepo)
      on_exit(fn -> Application.put_env(:phx_media_library, :repo, previous) end)

      log = capture_log(fn -> assert Scheduler.run_once(config([])) == :skipped end)
      assert log =~ "isn't running"
    end
  end

  describe "Oban runner" do
    setup do
      start_supervised!({Oban, name: __MODULE__.Oban, repo: Repo, testing: :manual})
      oban = [name: __MODULE__.Oban, queue: :default]
      %{config: config(enabled: true, runner: :oban, oban: oban, pause: 0), oban: oban}
    end

    defp jobs do
      Repo.all(from(j in Oban.Job, where: j.worker == ^inspect(Worker)))
    end

    test "startup inserts one job for `at:`, however many nodes start", %{config: config} do
      log = capture_log(fn -> Starter.run(config) end)
      Starter.run(config)

      assert [job] = jobs()
      assert job.state == "scheduled"

      assert DateTime.compare(job.scheduled_at, Schedule.next_run(DateTime.utc_now(), config.at)) ==
               :eq

      assert log =~ "queue :default"
    end

    test "a new `at:` moves the scheduled job at startup", %{config: config} do
      Starter.run(config)
      Starter.run(%{config | at: ~T[05:00:00]})

      assert [job] = jobs()
      assert job.scheduled_at.hour == 5
    end

    test "a run schedules the next one", %{config: config, oban: oban} do
      Application.put_env(:phx_media_library, :doctor_schedule,
        enabled: true,
        runner: :oban,
        oban: oban,
        pause: 0
      )

      attach([:phx_media_library, :doctor, :check])
      assert :ok = Oban.Testing.perform_job(Worker, %{}, repo: Repo)
      assert_received {:event, [:phx_media_library, :doctor, :check], _}

      assert [job] = jobs()

      assert DateTime.compare(job.scheduled_at, Schedule.next_run(DateTime.utc_now(), config.at)) ==
               :eq
    end

    test "a job of a switched-off schedule cancels without a next one" do
      Application.delete_env(:phx_media_library, :doctor_schedule)

      assert {:cancel, :schedule_disabled} = Oban.Testing.perform_job(Worker, %{}, repo: Repo)
      assert jobs() == []
    end

    test "a missing Oban instance is a warning", %{config: config} do
      config = %{config | oban: [name: NoSuchOban, queue: :default]}
      log = capture_log(fn -> assert Starter.run(config, attempts: 1) == :not_started end)
      assert log =~ "NoSuchOban"
    end
  end
end
