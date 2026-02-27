# LiveView Integration

PhxMediaLibrary ships with drop-in LiveView components that eliminate 150+ lines
of upload boilerplate. You get drag-and-drop uploads, live previews, progress
bars, and a media gallery — all collection-aware out of the box.

## Setup

Add the component imports to your `my_app_web.ex`:

```elixir
defp html_helpers do
  quote do
    # ... existing imports
    import PhxMediaLibrary.Components
    import PhxMediaLibrary.ViewHelpers
  end
end
```

## Upload + Gallery in a LiveView

Here's a complete LiveView that handles image uploads with a gallery display:

```elixir
defmodule MyAppWeb.PostLive.Edit do
  use MyAppWeb, :live_view
  use PhxMediaLibrary.LiveUpload

  def mount(%{"id" => id}, _session, socket) do
    post = Posts.get_post!(id)

    {:ok,
     socket
     |> assign(:post, post)
     |> allow_media_upload(:images, model: post, collection: :images)
     |> stream_existing_media(:media, post, :images)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_media", _params, socket) do
    case consume_media(socket, :images, socket.assigns.post, :images, notify: self()) do
      {:ok, media_items} ->
        {:noreply,
         socket
         |> stream_media_items(:media, media_items)
         |> put_flash(:info, "Uploaded #{length(media_items)} file(s)")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_media", %{"id" => id}, socket) do
    case delete_media_by_id(id, notify: self()) do
      :ok -> {:noreply, stream_delete_by_dom_id(socket, :media, "media-#{id}")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  # React to media lifecycle events
  def handle_info({:media_added, media_items}, socket) do
    {:noreply, assign(socket, :media_count, length(media_items))}
  end

  def handle_info({:media_removed, _media}, socket) do
    {:noreply, socket}
  end
end
```

## Template

```heex
<form phx-change="validate" phx-submit="save_media">
  <.media_upload
    upload={@uploads.images}
    id="post-images-upload"
    label="Upload Images"
    sublabel="JPG, PNG, WebP up to 10MB"
  />

  <button type="submit">Upload</button>
</form>

<.media_gallery
  media={@streams.media}
  id="post-gallery"
>
  <:item :let={{id, media}}>
    <.media_img media={media} conversion={:thumb} class="rounded-lg" />
  </:item>
  <:empty>
    <p>No images yet. Upload some above!</p>
  </:empty>
</.media_gallery>
```

## Components

### `<.media_upload>`

The primary upload component with full-featured UX:

- Drag-and-drop with visual feedback (`.MediaDropZone` JS hook)
- Live image previews via `<.live_img_preview>`
- Upload progress bars per entry
- Per-entry error display and cancel buttons
- Full-size and compact layouts
- Dark mode support
- Fully customizable via attrs, slots, and CSS classes

### `<.media_gallery>`

A stream-powered media grid:

- Stream-powered grid (2–6 configurable columns)
- Image thumbnails with delete-on-hover
- Document type icons (PDF, spreadsheet, archive, etc.)
- `:item` and `:empty` slots for custom rendering

### `<.media_upload_button>`

A compact inline variant for embedding upload triggers within forms or tight
layouts.

## `PhxMediaLibrary.LiveUpload` Helpers

`use PhxMediaLibrary.LiveUpload` imports these functions into your LiveView:

| Function | Purpose |
|----------|---------|
| `allow_media_upload/3` | Wraps `allow_upload/3` with collection-aware defaults (accept types, max entries, max file size) |
| `consume_media/5` | Consumes uploads and persists via `PhxMediaLibrary.add/2 \|> to_collection/2` |
| `stream_existing_media/4` | Loads existing media into a LiveView stream |
| `stream_media_items/3` | Inserts newly created media into a stream |
| `delete_media_by_id/2` | Deletes a media record and its files |
| `media_upload_errors/1` | Human-readable error strings for an upload |
| `media_entry_errors/2` | Human-readable error strings for an entry |
| `has_upload_entries?/1` | Whether the upload has any entries |
| `image_entry?/1` | Whether an entry is an image (for conditional previews) |
| `translate_upload_error/1` | Extensible error atom → string translation |

### Collection-Aware Uploads

`allow_media_upload/3` reads your collection definition and automatically
configures the LiveView upload:

- `:accept` — derived from the collection's `:accepts` MIME types
- `:max_entries` — derived from `:max_files`
- `:max_file_size` — derived from `:max_size`

```elixir
# These two are equivalent when collection has accepts: ~w(image/jpeg image/png), max_files: 10, max_size: 5_000_000
allow_media_upload(socket, :images, model: post, collection: :images)

allow_upload(socket, :images,
  accept: ~w(image/jpeg image/png),
  max_entries: 10,
  max_file_size: 5_000_000
)
```

## Event Notifications

Both `consume_media/5` and `delete_media_by_id/2` accept a `:notify` option.
When set to a pid (e.g. `self()`), lifecycle messages are sent to that process:

- `{:media_added, [Media.t()]}` — after successful upload
- `{:media_error, reason}` — when upload fails
- `{:media_removed, Media.t()}` — after successful deletion

Handle them in your LiveView via `handle_info/2`:

```elixir
def handle_info({:media_added, media_items}, socket) do
  {:noreply, put_flash(socket, :info, "#{length(media_items)} file(s) uploaded")}
end

def handle_info({:media_error, reason}, socket) do
  {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
end

def handle_info({:media_removed, media}, socket) do
  {:noreply, put_flash(socket, :info, "Removed #{media.file_name}")}
end
```

## View Helpers

For rendering media in templates (both LiveView and standard views),
PhxMediaLibrary provides rendering components.

### Simple Image

```heex
<.media_img media={@media} class="rounded-lg" />

<.media_img media={@media} conversion={:thumb} alt="Product image" />
```

### Responsive Image

```heex
<.responsive_img
  media={@media}
  sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 800px"
  class="w-full h-auto"
  alt="Hero image"
/>
```

### Picture Element (Art Direction)

```heex
<.picture
  media={@media}
  sources={[
    %{media: "(max-width: 768px)", conversion: :mobile},
    %{media: "(min-width: 769px)", conversion: :desktop}
  ]}
  alt="Responsive artwork"
/>
```
