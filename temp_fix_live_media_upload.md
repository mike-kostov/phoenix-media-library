# Plan: `PhxMediaLibrary.MediaLive` LiveComponent

## Problem

The `<.media_upload>` function component renders its own internal `<.form phx-change="validate">`.
This means:

1. You **cannot** wrap it in another `<form phx-submit="...">` — nested forms are invalid HTML,
   the submit never fires, files never transfer to the server.
2. Without a form submit, `consume_uploaded_entries/3` has nothing to consume — LiveView's upload
   protocol requires a form submission to trigger the binary transfer from browser to server.
3. The only workaround is `auto_upload: true` with a progress callback, which is non-obvious and
   forces a specific pattern on every consumer.

Every developer using the library hits this wall. The boilerplate for a working upload is ~80 lines
of repetitive code across mount, 5+ handle_event clauses, handle_info clauses, and template markup.

## Solution: `PhxMediaLibrary.MediaLive` LiveComponent

A self-contained LiveComponent that encapsulates the **entire** upload + gallery lifecycle.

### Consumer API (what developers write)

```heex
<%!-- Minimal usage — this is ALL you need --%>
<.live_component
  module={PhxMediaLibrary.MediaLive}
  id="album-photos"
  model={@album}
  collection={:photos}
/>

<%!-- Full options --%>
<.live_component
  module={PhxMediaLibrary.MediaLive}
  id="album-photos"
  model={@album}
  collection={:photos}
  max_file_size={20_000_000}
  max_entries={20}
  responsive={true}
  upload_label="Drop photos here"
  upload_sublabel="JPG, PNG, WebP, GIF up to 20MB"
  compact={false}
  columns={4}
  conversion={:thumb}
  show_gallery={true}
/>
```

### Required attrs

| Attr         | Type   | Description                          |
|--------------|--------|--------------------------------------|
| `id`         | string | Unique DOM id (required by LC)       |
| `model`      | struct | The Ecto struct (e.g. `@album`)      |
| `collection` | atom   | Collection name (e.g. `:photos`)     |

### Optional attrs

| Attr              | Type    | Default   | Description                                       |
|-------------------|---------|-----------|---------------------------------------------------|
| `max_file_size`   | integer | nil       | Override collection default                        |
| `max_entries`     | integer | nil       | Override collection default                        |
| `responsive`      | boolean | false     | Generate responsive images on upload               |
| `upload_label`    | string  | nil       | Label text above the drop zone                     |
| `upload_sublabel` | string  | nil       | Secondary helper text (e.g. accepted formats)      |
| `compact`         | boolean | false     | Compact single-line drop zone layout               |
| `columns`         | integer | 4         | Gallery grid columns (2–6)                         |
| `conversion`      | atom    | nil       | Conversion for gallery thumbnails                  |
| `show_gallery`    | boolean | true      | Show the gallery below the upload zone             |
| `class`           | string  | nil       | Additional CSS classes on the outer wrapper        |

### Internal implementation

**File:** `lib/phx_media_library/media_live.ex`

#### `update/2`

- Receives assigns from parent.
- On first mount (no `@upload_name` assigned yet):
  - Derives a unique upload name from `id` (e.g. `:media_upload_album_photos`).
  - Calls `Phoenix.LiveView.allow_upload/3` on the **parent socket** via
    `Phoenix.LiveComponent` lifecycle — actually, LiveComponents can call
    `allow_upload` in their own `update` using the socket they receive.
    **Important:** `allow_upload/3` works on LiveComponent sockets too.
  - Loads existing media via `PhxMediaLibrary.get_media(model, collection)`.
  - Streams them via `stream/3` with `dom_id: &"media-#{&1.id}"`.
- On subsequent updates (parent re-renders with new model, etc.):
  - Re-assigns model/collection if changed.
  - Does NOT re-allow upload (already configured).

#### `handle_event("validate", ...)` — target: `@myself`

- No-op. Required by LiveView upload protocol.

#### `handle_event("save_upload", ...)` — target: `@myself`

- Calls `Phoenix.LiveView.consume_uploaded_entries/3` on the socket.
- For each entry, calls `PhxMediaLibrary.add/2 |> to_collection/2`.
- If `responsive: true`, calls `PhxMediaLibrary.with_responsive_images/1`.
- Inserts new media into the stream via `stream_insert/3`.
- Sends `{PhxMediaLibrary.MediaLive, {:uploaded, collection, media_items}}` to parent.
- Sets flash on the component (or sends it to parent).

#### `handle_event("delete_media", %{"id" => id})` — target: `@myself`

- Fetches and deletes the media via `PhxMediaLibrary.Media` / repo.
- Removes from stream via `stream_delete_by_dom_id/3`.
- Sends `{PhxMediaLibrary.MediaLive, {:deleted, collection, media}}` to parent.

#### `handle_event("cancel_upload", %{"ref" => ref})` — target: `@myself`

- Calls `Phoenix.LiveView.cancel_upload/3`.

### Template structure

```heex
<div id={@id} class={["phx-media-live", @class]}>
  <%!-- Upload form — this is THE form, no nesting issue --%>
  <.form
    for={%{}}
    id={"#{@id}-upload-form"}
    phx-change="validate"
    phx-submit="save_upload"
    phx-target={@myself}
  >
    <%!-- Drop zone with phx-drop-target --%>
    <div phx-drop-target={@uploads[@upload_name].ref}>
      <%!-- Label --%>
      <label :if={@upload_label} ...>{@upload_label}</label>

      <%!-- Drop zone UI (reuse styles from _default_drop_zone / _compact_drop_zone) --%>
      <label class="...drop zone styles...">
        <.live_file_input upload={@uploads[@upload_name]} class="sr-only" />
        <%!-- Icon + text --%>
      </label>
    </div>

    <%!-- Upload errors --%>
    <%!-- Entry list with previews, progress, cancel buttons (phx-target={@myself}) --%>
    <%!-- Submit button (only shown when entries exist) --%>
    <button :if={@uploads[@upload_name].entries != []} type="submit">
      Upload N file(s)
    </button>
  </.form>

  <%!-- Gallery (stream-powered) --%>
  <div :if={@show_gallery} id={"#{@id}-gallery"} phx-update="stream" class="grid ...">
    <%!-- Empty state --%>
    <%!-- Media cards with delete buttons (phx-target={@myself}) --%>
  </div>
</div>
```

### Key design point: no nested forms

Because this is a LiveComponent, the `<.form>` it renders is the **top-level** form.
The `<.live_file_input>` lives directly inside it. When the user clicks the submit button,
`phx-submit="save_upload"` fires, the binary data transfers, and `consume_uploaded_entries`
works correctly.

This completely avoids the nested form problem that `<.media_upload>` has.

### Parent notification

When uploads complete or media is deleted, the component sends messages to the parent:

```elixir
send(self(), {PhxMediaLibrary.MediaLive, {:uploaded, :photos, [%Media{}, ...]}})
send(self(), {PhxMediaLibrary.MediaLive, {:deleted, :photos, %Media{}}})
```

The parent handles in `handle_info/2`:

```elixir
def handle_info({PhxMediaLibrary.MediaLive, {:uploaded, :photos, media_items}}, socket) do
  # Update counters, refresh related UI, etc.
  {:noreply, assign(socket, :photo_count, socket.assigns.photo_count + length(media_items))}
end

def handle_info({PhxMediaLibrary.MediaLive, {:deleted, :photos, _media}}, socket) do
  {:noreply, assign(socket, :photo_count, max(0, socket.assigns.photo_count - 1))}
end
```

Or ignore them entirely — the component handles its own UI state.

## Guide updates

### `guides/liveview.md`

1. **Lead with the LiveComponent** — the zero-boilerplate approach.
2. **Rename existing content to "Custom Upload UI"** — documents Option A:
   - Use `PhxMediaLibrary.LiveUpload` helpers
   - Build your own `<.form phx-submit="...">` with `<.live_file_input>` directly inside
   - Handle all events yourself
   - Use `<.media_gallery>` for display
3. **Document the nested form gotcha** — clearly explain that `<.media_upload>` renders its
   own `<.form>`, so you must NOT wrap it in another form. For custom UIs, use
   `<.live_file_input>` directly.

## Implementation order

1. Create `lib/phx_media_library/media_live.ex` — the LiveComponent
2. Add test in `test/phx_media_library/media_live_test.exs` — at least module compilation + attr checks
3. Update `guides/liveview.md` — restructure with LiveComponent first, custom approach second
4. Update `CHANGELOG.md` — add to [Unreleased]
5. Update gallery_app `show.ex` to use the new LiveComponent
6. Run `mix precommit` on both projects