defmodule PhxMediaLibrary.UploadLive do
  @moduledoc """
  A LiveView for tests: accepts uploads and, on submit, consumes them with
  `PhxMediaLibrary.LiveUpload.consume_media/5`, sending the result and the
  `:notify` messages to the test process.

  Session: `"post"`, `"collection"` and `"test_pid"`.
  """

  use Phoenix.LiveView

  alias PhxMediaLibrary.LiveUpload

  @impl true
  def mount(_params, %{"post" => post, "collection" => collection, "test_pid" => pid}, socket) do
    {:ok,
     socket
     |> assign(post: post, collection: collection, test_pid: pid)
     |> allow_upload(:files, accept: :any, max_entries: 5, max_file_size: 10_000_000)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id="upload-form" phx-submit="save" phx-change="validate">
      <.live_file_input upload={@uploads.files} />
    </form>
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", _params, socket) do
    %{post: post, collection: collection, test_pid: pid} = socket.assigns
    result = LiveUpload.consume_media(socket, :files, post, collection, notify: pid)
    send(pid, {:consumed, result})
    {:noreply, socket}
  end
end
