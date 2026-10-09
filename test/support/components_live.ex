defmodule PhxMediaLibrary.ComponentsLive do
  @moduledoc """
  A LiveView for tests that renders the upload components of
  `PhxMediaLibrary.Components` with a real upload config.

  Session: `"opts"`, extra assigns for `<.media_upload>` (string keys of
  its attributes).
  """

  use Phoenix.LiveView

  import PhxMediaLibrary.Components

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(
       opts: Map.new(session["opts"] || %{}, fn {k, v} -> {String.to_existing_atom(k), v} end)
     )
     |> allow_upload(:files, accept: ~w(.txt), max_entries: 2, max_file_size: 1_000)
     |> allow_upload(:avatar, accept: ~w(.jpg .png), max_entries: 1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id="form" phx-change="validate" phx-submit="save">
      <.media_upload upload={@uploads.files} id="drop" {@opts} />
      <.media_upload_button upload={@uploads.avatar} id="button" label="Pick a file" />
    </form>
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}
  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}
end
