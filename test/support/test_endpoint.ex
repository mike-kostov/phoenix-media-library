defmodule PhxMediaLibrary.TestEndpoint do
  @moduledoc "A Phoenix endpoint for LiveView tests (`live_isolated/3`), started by the test helper."

  use Phoenix.Endpoint, otp_app: :phx_media_library

  socket("/live", Phoenix.LiveView.Socket)
end
