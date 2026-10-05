# Idea: the doctor on a schedule

Captured 2026-10-05 (Mike). Agreed the same day; part of spec 02, F9.

## Problem

How might apps check their media's health regularly in production, and be
alerted, without writing a job themselves and without the library getting
in the way of their own work?

## Direction (agreed)

Managed entirely from the library's config. The library is an OTP
application with its own supervision tree, so the scheduler lives there;
apps don't change `application.ex` or their Oban crontab.

```elixir
config :phx_media_library, :doctor_schedule,
  enabled: true,                 # default false
  runner: :auto,                 # :oban | :internal | :auto (Oban when present)
  at: ~T[03:00:00],              # daily, UTC
  repair: [:missing_placeholder, :missing_conversions],   # default [] = report only
  oban: [name: Oban, queue: :default]
```

Each run calls `PhxMediaLibrary.Doctor` (F9), the same code as the mix
task and `bin/media_doctor`, and emits a telemetry event and a log line
with the counts, for alerting.

## Not interfering with the app

| Risk | Mitigation |
|---|---|
| Load: a full check reads every row and, on S3, makes a request per file (which costs money) | Off by default; a quiet hour; batches with a pause between them; `deep: false` |
| Several nodes running it | Oban runs it once; the internal runner takes a Postgres advisory lock |
| Unattended repairs: `rename` changes URLs, `fix` deletes records | Report only by default; only listed repairs run; `rename`, `fix` and `drop_originals` are refused on a schedule |
| The library starts before the app's Repo | The first run waits for its time, and skips with a log line if the Repo isn't up |
| Tests and dev | Off unless configured |
| We can't edit the app's Oban crontab | The job reschedules itself: each run inserts the next one, marked unique, into a queue the app names; a missing queue is a warning at startup, not a silent no-op |

## Decisions

- A daily `at:` time, not a cron expression: the internal runner would
  need a cron parser (another dependency). "Every N hours" can come later.
- `:auto` picks Oban when it is loaded and configured, else the internal
  runner.

## Later

- An admin page with the report and repair buttons (backlog, parking lot).
