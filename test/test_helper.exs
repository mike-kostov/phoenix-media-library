# capture_log: keep the suite output clean — logs (incl. the deliberate error/
# warning paths several tests exercise) are captured and only printed when a
# test actually fails.
ExUnit.start(capture_log: true)

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

# S3 tests run against a reused Ministack container (ADR-026), through
# Req like the rest of the library; tests can inspect the requests sent.
Application.put_env(:ex_aws, :http_client, PhxMediaLibrary.RecordingS3Client)

s3_available? =
  case PhxMediaLibrary.Ministack.ensure_started() do
    {:ok, _endpoint} ->
      PhxMediaLibrary.Ministack.create_bucket() == :ok

    {:error, reason} ->
      IO.puts("S3 tests excluded: #{reason}")
      false
  end

# Exclude integration tests whose service is not available
ExUnit.configure(
  exclude: if(db_available?, do: [], else: [:db]) ++ if(s3_available?, do: [], else: [:s3])
)
