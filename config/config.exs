import Config

config :phx_media_library,
  ecto_repos: [PhxMediaLibrary.TestRepo]

config :phx_media_library, PhxMediaLibrary.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "phx_media_library_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  priv: "priv/repo"

config :phx_media_library,
  repo: PhxMediaLibrary.TestRepo,
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
