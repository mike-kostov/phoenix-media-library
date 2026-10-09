defmodule PhxMediaLibrary.TestRepo do
  @moduledoc false

  # DB=sqlite builds into its own _build_sqlite (mix.exs), so the adapter
  # chosen here at compile time always matches the run.
  use Ecto.Repo,
    otp_app: :phx_media_library,
    adapter:
      if(System.get_env("DB") == "sqlite",
        do: Ecto.Adapters.SQLite3,
        else: Ecto.Adapters.Postgres
      )

  @doc "Whether the suite runs on SQLite (`DB=sqlite`)."
  def sqlite?, do: System.get_env("DB") == "sqlite"
end
