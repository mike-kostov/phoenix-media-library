import Config

config :phx_media_library,
  ecto_repos: [PhxMediaLibrary.TestRepo]

# The suite runs on Postgres, and on SQLite with DB=sqlite (spec 02, F10).
if System.get_env("DB") == "sqlite" do
  config :phx_media_library, PhxMediaLibrary.TestRepo,
    database:
      Path.expand(
        "../tmp/phx_media_library_test#{System.get_env("MIX_TEST_PARTITION")}.sqlite3",
        __DIR__
      ),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 5,
    busy_timeout: 10_000,
    journal_mode: :wal,
    priv: "priv/repo"
else
  config :phx_media_library, PhxMediaLibrary.TestRepo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "phx_media_library_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10,
    priv: "priv/repo"
end

config :phx_media_library,
  repo: PhxMediaLibrary.TestRepo,
  # Run conversions inline so they complete within each test (no Task.Supervisor
  # tasks outliving the sandbox → no stale/disconnect noise).
  async_processor: PhxMediaLibrary.AsyncProcessor.Inline,
  default_disk: :memory,
  disks: [
    memory: [
      adapter: PhxMediaLibrary.Storage.Memory,
      base_url: "/test-uploads"
    ],
    local: [
      adapter: PhxMediaLibrary.Storage.Disk,
      root: "tmp/test_uploads",
      base_url: "/uploads"
    ]
  ],
  responsive_images: [
    enabled: true,
    widths: [320, 640, 960],
    tiny_placeholder: true
  ]

config :logger, level: :warning
