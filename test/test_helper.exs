ExUnit.start()

# Configure the library for testing
Application.put_env(:phx_media_library, :repo, PhxMediaLibrary.TestRepo)

Application.put_env(:phx_media_library, :disks,
  local: [
    adapter: PhxMediaLibrary.Storage.Disk,
    root: "priv/static/uploads",
    base_url: "/uploads"
  ],
  memory: [
    adapter: PhxMediaLibrary.Storage.Memory,
    base_url: "/test-uploads"
  ]
)

# Start the Memory storage agent for tests that need it
{:ok, _} = PhxMediaLibrary.Storage.Memory.start_link()

# Start the TestRepo for integration tests that need a real database.
# If Postgres is not available, repo-dependent tests will be excluded
# via the :db tag.
db_available? =
  case PhxMediaLibrary.TestRepo.start_link() do
    {:ok, _pid} ->
      # Run migrations programmatically so the test DB is always up to date
      migrations_path =
        Path.join([
          Application.app_dir(:phx_media_library),
          "..",
          "..",
          "priv",
          "repo",
          "migrations"
        ])

      migrations_path =
        if File.dir?(migrations_path) do
          migrations_path
        else
          # Fallback for running from the project root
          Path.join(["priv", "repo", "migrations"])
        end

      if File.dir?(migrations_path) do
        Ecto.Migrator.run(PhxMediaLibrary.TestRepo, migrations_path, :up, all: true, log: false)
      end

      # Configure the sandbox mode for the repo
      Ecto.Adapters.SQL.Sandbox.mode(PhxMediaLibrary.TestRepo, :manual)
      true

    {:error, _reason} ->
      false
  end

# Exclude integration tests if the database is not available
unless db_available? do
  ExUnit.configure(exclude: [:db])
end
