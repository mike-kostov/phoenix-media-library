# LiveView Integration

PhxMediaLibrary provides two approaches for handling media uploads in LiveView:

1. **`MediaLive` LiveComponent** (recommended) — a single line of template code
   that handles everything: drag-and-drop, previews, progress, persistence,
   gallery display, and deletion.

2. **Custom Upload UI** — use the lower-level `LiveUpload` helpers and build
   your own form, drop zone, and event handlers for full control.

## Setup

### 1. Tailwind CSS source path

Make sure your `assets/css/app.css` includes the library's source path so
Tailwind v4 can detect the component classes (see
[Getting Started — Tailwind CSS Setup](getting-started.md#tailwind-css-setup)):

```css
/* PhxMediaLibrary — include both paths to support Hex deps and path deps.
   Tailwind v4 silently ignores paths that don't exist. */
@source "../../deps/phx_media_library/lib";
@source "../../../phx_media_library/lib";
```

Without this, styled elements like hover overlays, progress bars, and buttons
may be missing from the generated CSS.

### 2. Component imports

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

---

## Approach 1: `MediaLive` LiveComponent (Recommended)

The `MediaLive` LiveComponent eliminates **all** upload boilerplate. No
`use PhxMediaLibrary.LiveUpload`, no `handle_event` clauses, no
`allow_upload`, no `consume_media`. The component handles everything.

### Minimal Example

```elixir
defmodule MyAppWeb.PostLive.Show do
  use MyAppWeb, :live_view

  def mount(%{"id" => id}, _session, socket) do
    post = Posts.get_post!(id)
    {:ok, assign(socket, :post, post)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>{@post.title}</h1>

      <.live_component
        module={PhxMediaLibrary.MediaLive}
        id="post-images"
        model={@post}
        collection={:images}
      />
    </Layouts.app>
    """
  end
end
```

That's it. You get:

- Drag-and-drop upload zone with visual feedback
- Live image previews for selected files
- Upload progress bars per entry
- Error display (file too large, wrong type, too many files)
- Cancel buttons for pending uploads
- An "Upload N file(s)" submit button
- A media gallery grid with thumbnails
- Delete-on-hover for each media item
- Dark mode support

### Full Options

```heex
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
  class="my-custom-class"
  upload_class="my-dropzone"
  gallery_class="mt-6 grid gap-4 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4"
  button_class="btn btn-primary w-full"
/>
```

### Available Options

| Option           | Type    | Default | Description                                       |
|------------------|---------|---------|---------------------------------------------------|
| `id`             | string  | —       | **Required.** Unique DOM id                        |
| `model`          | struct  | —       | **Required.** The Ecto struct (e.g. `@album`)      |
| `collection`     | atom    | —       | **Required.** Collection name (e.g. `:photos`)     |
| `max_file_size`  | integer | nil     | Override collection's max file size (bytes)         |
| `max_entries`    | integer | nil     | Override how many files can be selected at once     |
| `responsive`     | boolean | false   | Generate responsive images on upload               |
| `upload_label`   | string  | nil     | Label text above the drop zone                     |
| `upload_sublabel`| string  | nil     | Secondary text (e.g. accepted formats)             |
| `compact`        | boolean | false   | Compact single-line drop zone layout               |
| `columns`        | integer | 4       | Gallery grid columns (2–6)                         |
| `conversion`     | atom    | nil     | Conversion for gallery thumbnails                  |
| `show_gallery`   | boolean | true    | Show the gallery below the upload zone             |
| `class`          | string  | nil     | Additional CSS classes on the outer wrapper        |
| `upload_class`   | string  | nil     | CSS classes on the drop zone wrapper               |
| `gallery_class`  | string  | nil     | Replaces default gallery grid classes              |
| `button_class`   | string  | nil     | Replaces default submit button classes             |

### How Upload Limits Are Derived

When `max_file_size`, `max_entries`, or accept types are not explicitly provided,
they are derived from your schema's collection configuration automatically:

| Collection config        | Derived `max_entries`                              |
|--------------------------|----------------------------------------------------|
| `single_file: true`      | **1** — single file picker (no `multiple` attr)    |
| `max_files: N`           | **N** — multi-file picker                          |
| Neither set              | **10** — sensible default, multi-file picker       |

For example, given these collections:

```elixir
def media_collections do
  [
    collection(:photos, accepts: ~w(image/jpeg image/png image/webp)),
    collection(:cover, single_file: true, accepts: ~w(image/jpeg image/png)),
    collection(:documents, max_files: 5, accepts: ~w(application/pdf))
  ]
end
```

- `:photos` → multi-file picker, up to 10 files (default)
- `:cover` → single-file picker, exactly 1 file
- `:documents` → multi-file picker, up to 5 files

You can always override at the component level with the `max_entries` option,
which takes precedence over the collection config. Similarly, `max_file_size`
overrides the collection's `:max_size`, and accept types are derived from
the collection's `:accepts` list.

### Customizing Styles

The component ships with sensible default styles using plain Tailwind utility
classes (`bg-zinc-50`, `text-blue-600`, `dark:bg-zinc-800`, etc.). These work
out of the box with any Tailwind-based project.

If your app uses a component library like **daisyUI**, or you simply want to
match your own design system, use the `upload_class`, `gallery_class`, and
`button_class` options to override the defaults:

| Option          | What it controls                                  | Default behavior                                        |
|-----------------|---------------------------------------------------|---------------------------------------------------------|
| `upload_class`  | The `<div>` wrapping the drop zone                | No extra classes (the drop zone itself has its own styles) |
| `gallery_class` | The gallery grid container (`phx-update="stream"`)| `"mt-6 grid gap-4"` + responsive column classes derived from `columns` |
| `button_class`  | The "Upload N file(s)" submit button              | Blue rounded button with hover/focus/dark states         |

When you pass a value, it **replaces** the default classes entirely (not
merged), giving you full control. When `nil` (the default), the built-in
styles are used.

#### Example: daisyUI integration

```heex
<.live_component
  module={PhxMediaLibrary.MediaLive}
  id="album-photos"
  model={@album}
  collection={:photos}
  button_class="btn btn-primary w-full"
  gallery_class="mt-6 grid gap-4 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4"
/>
```

#### Example: fully custom styles

```heex
<.live_component
  module={PhxMediaLibrary.MediaLive}
  id="post-docs"
  model={@post}
  collection={:documents}
  class="p-6 bg-gray-50 rounded-2xl"
  upload_class="max-w-md mx-auto"
  button_class="mt-4 px-6 py-3 bg-emerald-600 text-white rounded-full hover:bg-emerald-700 font-medium w-full text-center"
  gallery_class="mt-8 grid gap-6 grid-cols-1 sm:grid-cols-2"
/>
```

> **Tip:** The `class` option adds classes to the outermost wrapper `<div>`
> and is always _merged_ with the base `"phx-media-live"` class. The other
> three options (`upload_class`, `gallery_class`, `button_class`) _replace_
> their respective defaults when set.

### Reacting to Uploads and Deletions

The component sends messages to the parent LiveView so you can update related
state (counters, summaries, etc.):

```elixir
def handle_info({PhxMediaLibrary.MediaLive, {:uploaded, :photos, media_items}}, socket) do
  # media_items is a list of newly uploaded %Media{} structs
  {:noreply, assign(socket, :photo_count, socket.assigns.photo_count + length(media_items))}
end

def handle_info({PhxMediaLibrary.MediaLive, {:deleted, :photos, media}}, socket) do
  # media is the deleted %Media{} struct
  {:noreply, assign(socket, :photo_count, max(0, socket.assigns.photo_count - 1))}
end
```

You can safely ignore these messages if you don't need them.

### Multiple Collections on One Page

Use multiple `MediaLive` components with different `id` and `collection` values:

```heex
<%!-- Cover image (single file, compact) --%>
<.live_component
  module={PhxMediaLibrary.MediaLive}
  id="album-cover"
  model={@album}
  collection={:cover}
  compact={true}
  upload_sublabel="JPG, PNG, WebP up to 10MB"
/>

<%!-- Photo gallery (multi-file) --%>
<.live_component
  module={PhxMediaLibrary.MediaLive}
  id="album-photos"
  model={@album}
  collection={:photos}
  responsive={true}
  upload_label="Drop photos here"
  upload_sublabel="JPG, PNG, WebP, GIF up to 20MB"
  columns={4}
/>
```

Each component manages its own upload configuration and media stream independently.

---

## Approach 2: Custom Upload UI

For full control over the upload experience, use the lower-level `LiveUpload`
helpers and build your own form, event handlers, and template.

> **Important:** The `<.media_upload>` function component renders its own
> internal `<.form>`. You must **not** wrap it inside another `<form>` tag —
> nested forms are invalid HTML and will silently break file uploads. For
> custom UIs, use `<.live_file_input>` directly inside your own
> `<.form phx-submit="...">`.

### Complete Custom Example

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

  # Optional: react to media lifecycle events
  def handle_info({:media_added, _media_items}, socket), do: {:noreply, socket}
  def handle_info({:media_removed, _media}, socket), do: {:noreply, socket}
  def handle_info({:media_error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Media error: #{inspect(reason)}")}
  end
end
```

### Custom Template

Build your own `<.form>` with `<.live_file_input>` inside it. This is the key
difference from using `<.media_upload>` — you own the form, so submit works
correctly:

```heex
<.form
  for={%{}}
  id="media-upload-form"
  phx-change="validate"
  phx-submit="save_media"
>
  <%!-- Drop zone --%>
  <div phx-drop-target={@uploads.images.ref}>
    <label class="flex flex-col items-center justify-center w-full min-h-[180px]
                   border-2 border-dashed rounded-xl cursor-pointer
                   border-zinc-300 bg-zinc-50
                   hover:border-blue-400 hover:bg-blue-50/50
                   phx-drop-target-active:border-blue-500 phx-drop-target-active:bg-blue-50">
      <p class="text-sm text-zinc-700">
        <span class="text-blue-600">Click to upload</span> or drag and drop
      </p>
      <p class="mt-1 text-xs text-zinc-500">JPG, PNG, WebP up to 10MB</p>

      <.live_file_input upload={@uploads.images} class="sr-only" />
    </label>
  </div>

  <%!-- Entry previews with progress --%>
  <div :for={entry <- @uploads.images.entries} class="flex items-center gap-3 mt-3">
    <.live_img_preview :if={String.starts_with?(entry.client_type, "image/")}
      entry={entry} class="w-12 h-12 rounded object-cover" />

    <div class="flex-1">
      <p class="text-sm truncate">{entry.client_name}</p>
      <div class="w-full h-1.5 bg-zinc-200 rounded-full mt-1">
        <div class="h-full bg-blue-500 rounded-full" style={"width: #{entry.progress}%"} />
      </div>
    </div>

    <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref}
            class="text-zinc-400 hover:text-red-500">
      ✕
    </button>
  </div>

  <%!-- Upload errors --%>
  <p :for={err <- upload_errors(@uploads.images)}
     class="text-sm text-red-600 mt-2">
    {translate_upload_error(err)}
  </p>

  <%!-- Submit button --%>
  <button :if={@uploads.images.entries != []} type="submit"
          class="mt-4 px-4 py-2 bg-blue-600 text-white rounded-lg">
    Upload {length(@uploads.images.entries)} file(s)
  </button>
</.form>

<%!-- Gallery --%>
<.media_gallery media={@streams.media} id="post-gallery">
  <:item :let={{_id, media}}>
    <.media_img media={media} conversion={:thumb} class="rounded-lg" />
  </:item>
  <:empty>
    <p>No images yet. Upload some above!</p>
  </:empty>
</.media_gallery>
```

> **Why not use `<.media_upload>` here?** The `<.media_upload>` function
> component renders its own `<.form phx-change="validate">` internally.
> Placing it inside another `<form>` creates nested forms (invalid HTML),
> which causes the submit to silently fail and files never transfer to the
> server. When building a custom UI, always use `<.live_file_input>` directly
> inside your own form.

---

## Function Components

If you prefer the ready-made function components for parts of your UI (but
don't want the full `MediaLive` LiveComponent), here's what's available.

> **Nested form warning:** `<.media_upload>` and `<.media_upload_button>`
> each render their own `<.form>`. Do not place them inside another form.
> Use them standalone, paired with `auto_upload: true` on the upload config,
> or use the `MediaLive` LiveComponent instead.

### `<.media_upload>`

Drop zone with previews, progress, and error display:

```heex
<.media_upload
  upload={@uploads.images}
  id="post-images-upload"
  label="Upload Images"
  sublabel="JPG, PNG, WebP up to 10MB"
/>
```

### `<.media_gallery>`

Stream-powered media grid with delete support:

```heex
<.media_gallery
  media={@streams.media}
  id="post-gallery"
  columns={4}
  conversion={:thumb}
  delete_event="delete_media"
/>
```

### `<.media_upload_button>`

Compact inline upload trigger:

```heex
<.media_upload_button upload={@uploads.avatar} id="avatar-btn" label="Change photo" />
```

---

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

---

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

---

## View Helpers

For rendering media in templates (both LiveView and standard views),
PhxMediaLibrary provides rendering components.

### Simple Image

```heex
<.media_img media={@media} class="rounded-lg" />

<.media_img media={@media} conversion={:thumb} alt="Product image" />
```

> **Note:** Only pass a `conversion` when you know the conversion has been
> generated. If the conversion file doesn't exist yet, the URL will 404.
> Pass `conversion={nil}` (or omit it) to use the original file, which always
> exists.

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
