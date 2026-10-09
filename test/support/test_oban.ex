defmodule PhxMediaLibrary.TestOban do
  @moduledoc """
  Oban options for tests on either database: SQLite needs Oban's Lite
  engine and a notifier that doesn't use Postgres.
  """

  @doc "Options for `{Oban, opts}` in tests, merged over `extra`."
  def opts(extra \\ []) do
    adapter =
      if PhxMediaLibrary.TestRepo.sqlite?(),
        do: [engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG],
        else: []

    [repo: PhxMediaLibrary.TestRepo, testing: :manual] ++ adapter ++ extra
  end
end
