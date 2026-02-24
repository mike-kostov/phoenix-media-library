defmodule PhxMediaLibrary.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Task supervisor for async processing
      {Task.Supervisor, name: PhxMediaLibrary.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: PhxMediaLibrary.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
