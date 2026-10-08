defmodule PhxMediaLibrary.Application do
  @moduledoc false

  use Application

  alias PhxMediaLibrary.Doctor.Schedule

  @impl true
  def start(_type, _args) do
    # The counter that keeps media ids strictly increasing.
    PhxMediaLibrary.UUIDv7.init()

    children =
      [
        # Task supervisor for async processing
        {Task.Supervisor, name: PhxMediaLibrary.TaskSupervisor}
      ] ++ Schedule.children()

    opts = [strategy: :one_for_one, name: PhxMediaLibrary.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
