defmodule PhxMediaLibrary.MediaLiveHost do
  @moduledoc """
  A LiveView for tests that renders `PhxMediaLibrary.MediaLive` and
  forwards its notifications to the test process.

  Session: `"post"`, `"collection"`, `"test_pid"` and optional `"opts"`
  (extra component assigns).
  """

  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       post: session["post"],
       collection: session["collection"],
       test_pid: session["test_pid"],
       opts: session["opts"] || %{}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PhxMediaLibrary.MediaLive}
      id="post-media"
      model={@post}
      collection={@collection}
      {@opts}
    />
    """
  end

  @impl true
  def handle_info({PhxMediaLibrary.MediaLive, message}, socket) do
    send(socket.assigns.test_pid, {:media_live, message})
    {:noreply, socket}
  end
end
