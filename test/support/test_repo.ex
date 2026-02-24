defmodule PhxMediaLibrary.TestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :phx_media_library,
    adapter: Ecto.Adapters.Postgres
end
