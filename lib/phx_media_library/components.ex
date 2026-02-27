defmodule PhxMediaLibrary.Components do
  @moduledoc """
  Ready-to-use Phoenix LiveView components for media uploads and galleries.

  These components eliminate the boilerplate of building file upload UIs in
  Phoenix LiveView. They handle drag-and-drop, progress bars, image previews,
  error display, and existing media management out of the box.

  ## Setup

  Add to your `my_app_web.ex` html_helpers:

      defp html_helpers do
        quote do
          # ... existing imports
          import PhxMediaLibrary.Components
          import PhxMediaLibrary.ViewHelpers
        end
      end

  ## Quick Start

      # In your LiveView mount:
      def mount(_params, _session, socket) do
        use PhxMediaLibrary.LiveUpload

        post = Posts.get_post!(id)

        {:ok,
         socket
         |> assign(:post, post)
         |> allow_media_upload(:images, model: post, collection: :images)
         |> stream_existing_media(:media, post, :images)}
      end

      # In your template:
      <.media_upload
        upload={@uploads.images}
        id="post-images-upload"
      />

      <.media_gallery
        media={@streams.media}
        id="post-gallery"
      />
  """

  use Phoenix.Component

  alias PhxMediaLibrary.LiveUpload
  alias PhxMediaLibrary.Media

  # ---------------------------------------------------------------------------
  # media_upload component
  # ---------------------------------------------------------------------------

  @doc """
  Renders a complete media upload zone with drag-and-drop, previews, and progress.

  This component renders:
  - A drop zone with a file picker button
  - Live image previews for selected files
  - Upload progress bars per entry
  - Error messages for invalid files
  - Cancel buttons for pending uploads

  The parent LiveView must call `allow_upload/3` or `allow_media_upload/3`
  and handle at minimum a `"validate"` event (can be a no-op) and a submit
  event that calls `consume_media/5` or `consume_uploaded_entries/3`.

  ## Attributes

  - `upload` (required) — the upload config from `@uploads.name`
  - `id` (required) — unique DOM id for the component
  - `label` — text label above the drop zone
  - `sublabel` — secondary text below the icon (e.g. accepted formats)
  - `class` — additional CSS classes on the outer wrapper
  - `compact` — render a compact single-line version (default: false)
  - `disabled` — disable the upload zone (default: false)
  - `cancel_event` — the phx-click event name for cancelling an entry (default: "cancel_upload")
  - `cancel_target` — optional phx-target for the cancel event

  ## Slots

  - `drop_zone` — override the default drop zone content entirely

  ## Examples

      <%!-- Basic usage --%>
      <.media_upload upload={@uploads.images} id="images-upload" />

      <%!-- With labels --%>
      <.media_upload
        upload={@uploads.images}
        id="images-upload"
        label="Upload Images"
        sublabel="JPG, PNG, WebP up to 10MB"
      />

      <%!-- Compact variant for single-file uploads --%>
      <.media_upload
        upload={@uploads.avatar}
        id="avatar-upload"
        compact={true}
        label="Profile Photo"
      />

      <%!-- Custom drop zone content --%>
      <.media_upload upload={@uploads.docs} id="docs-upload">
        <:drop_zone>
          <div class="text-center p-8">
            <p class="text-lg font-semibold">Drop your documents here</p>
          </div>
        </:drop_zone>
      </.media_upload>
  """
  attr(:upload, :any, required: true, doc: "the upload config from @uploads")
  attr(:id, :string, required: true, doc: "unique DOM id")
  attr(:label, :string, default: nil, doc: "label text above the drop zone")
  attr(:sublabel, :string, default: nil, doc: "secondary helper text")
  attr(:class, :string, default: nil, doc: "additional CSS classes")
  attr(:compact, :boolean, default: false, doc: "compact single-line layout")
  attr(:disabled, :boolean, default: false, doc: "disable the upload zone")
  attr(:cancel_event, :string, default: "cancel_upload", doc: "event name for cancel")
  attr(:cancel_target, :any, default: nil, doc: "phx-target for cancel event")

  slot(:drop_zone, doc: "override default drop zone content")

  def media_upload(assigns) do
    ~H"""
    <div id={@id} class={["phx-media-upload", @class]}>
      <%!-- Label --%>
      <label :if={@label} class="block text-sm font-medium text-zinc-700 dark:text-zinc-300 mb-2">
        {@label}
      </label>

      <%!-- Drop zone --%>
      <div
        class={[
          "relative group",
          not @disabled && "cursor-pointer",
          @disabled && "opacity-50 cursor-not-allowed"
        ]}
        phx-drop-target={not @disabled && @upload.ref}
      >
        <.form
          for={%{}}
          id={"#{@id}-form"}
          phx-change="validate"
          class="contents"
        >
          <%= if @drop_zone != [] do %>
            {render_slot(@drop_zone)}
            <.live_file_input upload={@upload} class="sr-only" tabindex={if @disabled, do: "-1"} />
          <% else %>
            <%= if @compact do %>
              <._compact_drop_zone upload={@upload} sublabel={@sublabel} disabled={@disabled} />
            <% else %>
              <._default_drop_zone upload={@upload} sublabel={@sublabel} disabled={@disabled} />
            <% end %>
          <% end %>
        </.form>
      </div>

      <%!-- Upload-level errors --%>
      <._upload_errors upload={@upload} />

      <%!-- Entries: previews, progress, per-entry errors --%>
      <div
        :if={@upload.entries != []}
        class="mt-4 space-y-3"
        id={"#{@id}-entries"}
      >
        <._upload_entry
          :for={entry <- @upload.entries}
          entry={entry}
          upload={@upload}
          cancel_event={@cancel_event}
          cancel_target={@cancel_target}
          id={"#{@id}-entry-#{entry.ref}"}
        />
      </div>

      <%!-- Colocated JS hook for client-side preview enhancement --%>
      <._media_drop_zone_hook />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # media_gallery component
  # ---------------------------------------------------------------------------

  @doc """
  Renders a gallery of existing media items with delete support.

  Designed to work with LiveView streams. Each media item is rendered as a
  card with a thumbnail (for images) or file icon (for documents), the
  filename, file size, and a delete button.

  ## Attributes

  - `media` (required) — the stream from `@streams.media`
  - `id` (required) — unique DOM id for the gallery container
  - `class` — additional CSS classes
  - `conversion` — the conversion to display for image thumbnails (default: nil = original)
  - `delete_event` — the phx-click event name for deleting (default: "delete_media")
  - `delete_target` — optional phx-target for the delete event
  - `confirm_delete` — show a JS confirmation before delete (default: true)
  - `confirm_message` — the confirmation prompt text
  - `columns` — grid column count hint: 2, 3, 4, 5, 6 (default: 4)

  ## Slots

  - `item` — override rendering of each media item. Receives the media struct.
  - `empty` — content to show when the gallery is empty.

  ## Examples

      <%!-- Basic usage with streams --%>
      <.media_gallery
        media={@streams.media}
        id="post-gallery"
      />

      <%!-- With custom columns and conversion --%>
      <.media_gallery
        media={@streams.media}
        id="post-gallery"
        conversion={:thumb}
        columns={3}
      />

      <%!-- Custom item rendering --%>
      <.media_gallery media={@streams.media} id="gallery">
        <:item :let={{_id, media}}>
          <div class="relative aspect-square rounded-lg overflow-hidden">
            <img src={PhxMediaLibrary.url(media, :thumb)} class="object-cover w-full h-full" />
          </div>
        </:item>
        <:empty>
          <p class="text-zinc-400 text-center py-12">No media uploaded yet.</p>
        </:empty>
      </.media_gallery>
  """
  attr(:media, :any, required: true, doc: "the stream from @streams")
  attr(:id, :string, required: true, doc: "unique DOM id for the gallery container")
  attr(:class, :string, default: nil, doc: "additional CSS classes")
  attr(:conversion, :atom, default: nil, doc: "image conversion for thumbnails")
  attr(:delete_event, :string, default: "delete_media", doc: "event name for delete")
  attr(:delete_target, :any, default: nil, doc: "phx-target for delete event")
  attr(:confirm_delete, :boolean, default: true, doc: "show confirmation dialog")

  attr(:confirm_message, :string,
    default: "Are you sure you want to delete this file?",
    doc: "confirm text"
  )

  attr(:columns, :integer, default: 4, doc: "grid columns (2-6)")

  slot(:item, doc: "override item rendering — receives {dom_id, media}")
  slot(:empty, doc: "content when gallery is empty")

  def media_gallery(assigns) do
    grid_class =
      case assigns.columns do
        2 -> "grid-cols-1 sm:grid-cols-2"
        3 -> "grid-cols-1 sm:grid-cols-2 lg:grid-cols-3"
        4 -> "grid-cols-2 sm:grid-cols-3 lg:grid-cols-4"
        5 -> "grid-cols-2 sm:grid-cols-3 lg:grid-cols-5"
        6 -> "grid-cols-3 sm:grid-cols-4 lg:grid-cols-6"
        _ -> "grid-cols-2 sm:grid-cols-3 lg:grid-cols-4"
      end

    assigns = assign(assigns, :grid_class, grid_class)

    ~H"""
    <div
      id={@id}
      phx-update="stream"
      class={[
        "grid gap-4",
        @grid_class,
        @class
      ]}
    >
      <%!-- Empty state: visible only when it's the sole child --%>
      <div
        :if={@empty != []}
        id={"#{@id}-empty"}
        class="hidden only:flex col-span-full items-center justify-center"
      >
        {render_slot(@empty)}
      </div>

      <div
        :for={{dom_id, media} <- @media}
        id={dom_id}
        class="group relative"
      >
        <%= if @item != [] do %>
          {render_slot(@item, {dom_id, media})}
        <% else %>
          <._gallery_card
            media={media}
            conversion={@conversion}
            delete_event={@delete_event}
            delete_target={@delete_target}
            confirm_delete={@confirm_delete}
            confirm_message={@confirm_message}
          />
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # media_upload_area — a minimal upload-only variant (no gallery)
  # ---------------------------------------------------------------------------

  @doc """
  Renders a minimal file input button without the full drop zone.

  Useful for embedding uploads inline within forms or other UI elements
  where the full drop zone is too large.

  ## Attributes

  - `upload` (required) — the upload config from `@uploads.name`
  - `id` (required) — unique DOM id
  - `label` — button label text (default: "Choose file")
  - `class` — additional CSS classes on the wrapper
  - `icon` — hero icon name (default: "hero-arrow-up-tray")

  ## Examples

      <.media_upload_button upload={@uploads.avatar} id="avatar-btn" label="Change photo" />
  """
  attr(:upload, :any, required: true, doc: "the upload config from @uploads")
  attr(:id, :string, required: true, doc: "unique DOM id")
  attr(:label, :string, default: "Choose file", doc: "button label")
  attr(:class, :string, default: nil, doc: "additional CSS classes")
  attr(:icon, :string, default: "hero-arrow-up-tray", doc: "icon name")

  def media_upload_button(assigns) do
    ~H"""
    <div id={@id} class={["inline-flex", @class]}>
      <.form for={%{}} id={"#{@id}-form"} phx-change="validate" class="contents">
        <label class={[
          "inline-flex items-center gap-2 px-4 py-2 rounded-lg cursor-pointer",
          "text-sm font-medium",
          "bg-zinc-100 text-zinc-700 hover:bg-zinc-200",
          "dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700",
          "transition-colors duration-150"
        ]}>
          <._upload_icon name={@icon} />
          {@label}
          <.live_file_input upload={@upload} class="sr-only" />
        </label>
      </.form>
    </div>
    """
  end

  # ===========================================================================
  # Private sub-components
  # ===========================================================================

  # -- Default drop zone (full size) ------------------------------------------

  attr(:upload, :any, required: true)
  attr(:sublabel, :string, default: nil)
  attr(:disabled, :boolean, default: false)

  defp _default_drop_zone(assigns) do
    ~H"""
    <label class={[
      "flex flex-col items-center justify-center w-full",
      "min-h-[180px] px-6 py-10",
      "border-2 border-dashed rounded-xl",
      "transition-all duration-200 ease-in-out",
      not @disabled && [
        "border-zinc-300 dark:border-zinc-600",
        "bg-zinc-50 dark:bg-zinc-900",
        "hover:border-blue-400 hover:bg-blue-50/50",
        "dark:hover:border-blue-500 dark:hover:bg-blue-950/30",
        "phx-drop-target-active:border-blue-500 phx-drop-target-active:bg-blue-50",
        "dark:phx-drop-target-active:border-blue-400 dark:phx-drop-target-active:bg-blue-950/50",
        "phx-drop-target-active:scale-[1.01]"
      ],
      @disabled && [
        "border-zinc-200 dark:border-zinc-700",
        "bg-zinc-100 dark:bg-zinc-900/50"
      ]
    ]}>
      <div class="flex flex-col items-center gap-3 pointer-events-none">
        <div class={[
          "flex items-center justify-center w-12 h-12 rounded-full",
          "bg-blue-100 text-blue-600",
          "dark:bg-blue-900/50 dark:text-blue-400",
          "transition-transform duration-200",
          "group-hover:scale-110"
        ]}>
          <._upload_icon name="hero-arrow-up-tray" class="w-6 h-6" />
        </div>

        <div class="text-center">
          <p class="text-sm font-medium text-zinc-700 dark:text-zinc-300">
            <span class="text-blue-600 dark:text-blue-400">Click to upload</span>
            or drag and drop
          </p>
          <p :if={@sublabel} class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
            {@sublabel}
          </p>
        </div>
      </div>

      <.live_file_input
        upload={@upload}
        class="sr-only"
        tabindex={if @disabled, do: "-1"}
      />
    </label>
    """
  end

  # -- Compact drop zone (single-line) ----------------------------------------

  attr(:upload, :any, required: true)
  attr(:sublabel, :string, default: nil)
  attr(:disabled, :boolean, default: false)

  defp _compact_drop_zone(assigns) do
    ~H"""
    <label class={[
      "flex items-center gap-4 w-full px-4 py-3",
      "border-2 border-dashed rounded-lg",
      "transition-all duration-200 ease-in-out",
      not @disabled && [
        "border-zinc-300 dark:border-zinc-600",
        "bg-zinc-50 dark:bg-zinc-900",
        "hover:border-blue-400 hover:bg-blue-50/50",
        "dark:hover:border-blue-500 dark:hover:bg-blue-950/30",
        "phx-drop-target-active:border-blue-500 phx-drop-target-active:bg-blue-50",
        "dark:phx-drop-target-active:border-blue-400 dark:phx-drop-target-active:bg-blue-950/50"
      ],
      @disabled && [
        "border-zinc-200 dark:border-zinc-700",
        "bg-zinc-100 dark:bg-zinc-900/50"
      ]
    ]}>
      <div class={[
        "flex items-center justify-center w-10 h-10 rounded-full shrink-0",
        "bg-blue-100 text-blue-600",
        "dark:bg-blue-900/50 dark:text-blue-400"
      ]}>
        <._upload_icon name="hero-arrow-up-tray" class="w-5 h-5" />
      </div>

      <div class="min-w-0 pointer-events-none">
        <p class="text-sm font-medium text-zinc-700 dark:text-zinc-300 truncate">
          <span class="text-blue-600 dark:text-blue-400">Choose a file</span>
          or drag it here
        </p>
        <p :if={@sublabel} class="text-xs text-zinc-500 dark:text-zinc-400 truncate">
          {@sublabel}
        </p>
      </div>

      <.live_file_input
        upload={@upload}
        class="sr-only"
        tabindex={if @disabled, do: "-1"}
      />
    </label>
    """
  end

  # -- Single upload entry (preview + progress + errors) -----------------------

  attr(:entry, :any, required: true)
  attr(:upload, :any, required: true)
  attr(:cancel_event, :string, required: true)
  attr(:cancel_target, :any, default: nil)
  attr(:id, :string, required: true)

  defp _upload_entry(assigns) do
    entry_errors = Phoenix.Component.upload_errors(assigns.upload, assigns.entry)
    assigns = assign(assigns, :entry_errors, entry_errors)

    ~H"""
    <div id={@id} class={[
      "flex items-center gap-3 p-3 rounded-lg",
      "bg-white dark:bg-zinc-800",
      "border",
      @entry_errors == [] && "border-zinc-200 dark:border-zinc-700",
      @entry_errors != [] && "border-red-300 dark:border-red-700"
    ]}>
      <%!-- Preview or file icon --%>
      <div class="shrink-0 w-12 h-12 rounded-lg overflow-hidden bg-zinc-100 dark:bg-zinc-700 flex items-center justify-center">
        <%= if image_entry?(@entry) do %>
          <.live_img_preview entry={@entry} class="w-12 h-12 object-cover" />
        <% else %>
          <._upload_icon name="hero-document" class="w-6 h-6 text-zinc-400 dark:text-zinc-500" />
        <% end %>
      </div>

      <%!-- File info + progress --%>
      <div class="flex-1 min-w-0">
        <div class="flex items-center justify-between gap-2">
          <p class="text-sm font-medium text-zinc-700 dark:text-zinc-300 truncate">
            {@entry.client_name}
          </p>
          <span class="text-xs text-zinc-500 dark:text-zinc-400 shrink-0 tabular-nums">
            {format_file_size(@entry.client_size)}
          </span>
        </div>

        <%!-- Progress bar --%>
        <div :if={@entry.progress > 0 && @entry.progress < 100} class="mt-1.5">
          <div class="w-full h-1.5 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div
              class="h-full bg-blue-500 rounded-full transition-all duration-300 ease-out"
              style={"width: #{@entry.progress}%"}
            />
          </div>
        </div>

        <%!-- Completed indicator --%>
        <div :if={@entry.progress == 100 && @entry_errors == []} class="mt-1">
          <span class="inline-flex items-center gap-1 text-xs text-emerald-600 dark:text-emerald-400">
            <._upload_icon name="hero-check-circle" class="w-3.5 h-3.5" />
            Ready
          </span>
        </div>

        <%!-- Per-entry errors --%>
        <div :if={@entry_errors != []} class="mt-1">
          <p
            :for={err <- @entry_errors}
            class="text-xs text-red-600 dark:text-red-400"
          >
            {LiveUpload.translate_upload_error(err)}
          </p>
        </div>
      </div>

      <%!-- Cancel button --%>
      <button
        type="button"
        phx-click={@cancel_event}
        phx-value-ref={@entry.ref}
        phx-target={@cancel_target}
        class={[
          "shrink-0 p-1.5 rounded-lg",
          "text-zinc-400 hover:text-red-500 hover:bg-red-50",
          "dark:text-zinc-500 dark:hover:text-red-400 dark:hover:bg-red-950/30",
          "transition-colors duration-150",
          "focus:outline-none focus:ring-2 focus:ring-red-500/40"
        ]}
        aria-label={"Cancel upload of #{@entry.client_name}"}
      >
        <._upload_icon name="hero-x-mark" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  defp image_entry?(%{client_type: client_type}) do
    String.starts_with?(client_type, "image/")
  end

  defp image_entry?(_), do: false

  # -- Upload-level errors ----------------------------------------------------

  attr(:upload, :any, required: true)

  defp _upload_errors(assigns) do
    errors = Phoenix.Component.upload_errors(assigns.upload)
    assigns = assign(assigns, :errors, errors)

    ~H"""
    <div :if={@errors != []} class="mt-2 space-y-1">
      <p
        :for={err <- @errors}
        class="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400"
      >
        <._upload_icon name="hero-exclamation-circle" class="w-4 h-4 shrink-0" />
        {LiveUpload.translate_upload_error(err)}
      </p>
    </div>
    """
  end

  # -- Default gallery card ----------------------------------------------------

  attr(:media, :any, required: true)
  attr(:conversion, :atom, default: nil)
  attr(:delete_event, :string, required: true)
  attr(:delete_target, :any, default: nil)
  attr(:confirm_delete, :boolean, default: true)
  attr(:confirm_message, :string, default: "Are you sure you want to delete this file?")

  defp _gallery_card(assigns) do
    is_image = image_media?(assigns.media)
    assigns = assign(assigns, :is_image, is_image)

    ~H"""
    <div class={[
      "relative rounded-xl overflow-hidden",
      "bg-white dark:bg-zinc-800",
      "border border-zinc-200 dark:border-zinc-700",
      "shadow-sm hover:shadow-md",
      "transition-all duration-200"
    ]}>
      <%!-- Thumbnail / icon area --%>
      <div class={[
        "relative aspect-square",
        "bg-zinc-100 dark:bg-zinc-800",
        "flex items-center justify-center overflow-hidden"
      ]}>
        <%= if @is_image do %>
          <img
            src={PhxMediaLibrary.url(@media, @conversion)}
            alt={@media.file_name}
            class="w-full h-full object-cover"
            loading="lazy"
          />
        <% else %>
          <div class="flex flex-col items-center gap-2">
            <._file_type_icon mime_type={@media.mime_type} />
            <span class="text-xs font-medium text-zinc-500 dark:text-zinc-400 uppercase">
              {file_extension(@media.file_name)}
            </span>
          </div>
        <% end %>

        <%!-- Hover overlay with delete button --%>
        <div class={[
          "absolute inset-0",
          "bg-black/0 group-hover:bg-black/40",
          "flex items-center justify-center",
          "opacity-0 group-hover:opacity-100",
          "transition-all duration-200"
        ]}>
          <button
            type="button"
            phx-click={
              if @confirm_delete do
                Phoenix.LiveView.JS.push(@delete_event, value: %{id: @media.id})
                |> Phoenix.LiveView.JS.exec("data-confirm", to: "body")
              else
                @delete_event
              end
            }
            phx-value-id={unless @confirm_delete, do: @media.id}
            phx-target={@delete_target}
            data-confirm={if @confirm_delete, do: @confirm_message}
            class={[
              "p-2 rounded-full",
              "bg-white/90 text-red-600 hover:bg-red-600 hover:text-white",
              "shadow-lg",
              "transition-colors duration-150",
              "focus:outline-none focus:ring-2 focus:ring-white/50"
            ]}
            aria-label={"Delete #{@media.file_name}"}
          >
            <._upload_icon name="hero-trash" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <%!-- File info bar --%>
      <div class="px-3 py-2">
        <p class="text-xs font-medium text-zinc-700 dark:text-zinc-300 truncate" title={@media.file_name}>
          {@media.file_name}
        </p>
        <p class="text-xs text-zinc-400 dark:text-zinc-500">
          {format_file_size(@media.size)}
        </p>
      </div>
    </div>
    """
  end

  # -- File type icon (for non-image media) ------------------------------------

  attr(:mime_type, :string, required: true)

  defp _file_type_icon(assigns) do
    icon_name =
      cond do
        String.starts_with?(assigns.mime_type, "video/") -> "hero-film"
        String.starts_with?(assigns.mime_type, "audio/") -> "hero-musical-note"
        assigns.mime_type == "application/pdf" -> "hero-document-text"
        String.contains?(assigns.mime_type, "spreadsheet") -> "hero-table-cells"
        String.contains?(assigns.mime_type, "presentation") -> "hero-presentation-chart-bar"
        String.contains?(assigns.mime_type, "zip") -> "hero-archive-box"
        String.contains?(assigns.mime_type, "compressed") -> "hero-archive-box"
        true -> "hero-document"
      end

    assigns = assign(assigns, :icon_name, icon_name)

    ~H"""
    <div class={[
      "w-14 h-14 rounded-2xl",
      "bg-zinc-200/80 dark:bg-zinc-700",
      "flex items-center justify-center"
    ]}>
      <._upload_icon name={@icon_name} class="w-7 h-7 text-zinc-500 dark:text-zinc-400" />
    </div>
    """
  end

  # -- Minimal icon component (delegates to core_components pattern) -----------
  #
  # We render hero icons via the standard Phoenix pattern using
  # `<span class="hero-icon-name">` which is picked up by the heroicons
  # plugin configured in the consuming application's Tailwind setup.
  # If the consuming app uses a different icon system, they can override
  # the gallery card via the :item slot.

  attr(:name, :string, required: true)
  attr(:class, :string, default: "w-5 h-5")

  defp _upload_icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # -- Colocated JS hook for drop zone animation ------------------------------

  defp _media_drop_zone_hook(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MediaDropZone">
      export default {
        mounted() {
          const zone = this.el.closest('.phx-media-upload')
          if (!zone) return

          const dropTarget = zone.querySelector('[phx-drop-target]')
          if (!dropTarget) return

          // Enhanced visual feedback during drag operations.
          // The built-in phx-drop-target-active class handles basic styling.
          // This hook adds a pulsing animation for extra delight.
          let dragCounter = 0

          dropTarget.addEventListener('dragenter', (e) => {
            dragCounter++
            dropTarget.classList.add('phx-media-dragging')
          })

          dropTarget.addEventListener('dragleave', (e) => {
            dragCounter--
            if (dragCounter === 0) {
              dropTarget.classList.remove('phx-media-dragging')
            }
          })

          dropTarget.addEventListener('drop', (e) => {
            dragCounter = 0
            dropTarget.classList.remove('phx-media-dragging')

            // Add a brief "received" flash
            dropTarget.classList.add('phx-media-dropped')
            setTimeout(() => {
              dropTarget.classList.remove('phx-media-dropped')
            }, 600)
          })
        }
      }
    </script>
    """
  end

  # ===========================================================================
  # Formatting helpers
  # ===========================================================================

  @doc false
  defp format_file_size(nil), do: ""

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 ->
        format_unit(bytes, 1_000_000_000, "GB")

      bytes >= 1_000_000 ->
        format_unit(bytes, 1_000_000, "MB")

      bytes >= 1_000 ->
        format_unit(bytes, 1_000, "KB")

      true ->
        "#{bytes} B"
    end
  end

  defp format_unit(bytes, divisor, unit) do
    value = bytes / divisor
    formatted = :erlang.float_to_binary(Float.round(value, 1), decimals: 1)
    "#{formatted} #{unit}"
  end

  defp image_media?(%Media{mime_type: mime_type}) when is_binary(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp image_media?(%{mime_type: mime_type}) when is_binary(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp image_media?(_), do: false

  defp file_extension(filename) when is_binary(filename) do
    filename
    |> Path.extname()
    |> String.trim_leading(".")
  end

  defp file_extension(_), do: ""
end
