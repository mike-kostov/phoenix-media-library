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
