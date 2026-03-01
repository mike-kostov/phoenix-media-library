defmodule PhxMediaLibrary.MediaLive do
  @moduledoc """
  A self-contained LiveComponent for media uploads and gallery display.

  `MediaLive` eliminates all upload boilerplate. Drop it into any LiveView
  and get drag-and-drop uploads, live previews, progress bars, a media
  gallery with delete support, and automatic persistence via PhxMediaLibrary
  — all in a single line of template code.

  ## Quick Start

      <.live_component
        module={PhxMediaLibrary.MediaLive}
        id="post-images"
        model={@post}
        collection={:images}
      />

  That's it. No `use PhxMediaLibrary.LiveUpload`, no `handle_event` clauses,
  no `allow_upload`, no `consume_media`. The component handles everything.

  ## Options

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

  ## Parent Notifications

  The component notifies the parent LiveView via `send/2` so you can react
  to uploads and deletions (update counters, refresh related data, etc.):

      def handle_info({PhxMediaLibrary.MediaLive, {:uploaded, :photos, media_items}}, socket) do
        {:noreply, assign(socket, :photo_count, socket.assigns.photo_count + length(media_items))}
      end

      def handle_info({PhxMediaLibrary.MediaLive, {:deleted, :photos, _media}}, socket) do
        {:noreply, assign(socket, :photo_count, max(0, socket.assigns.photo_count - 1))}
      end

  You can safely ignore these messages if you don't need them.

  ## How It Works

  Internally the component:

  1. Calls `allow_upload/3` with collection-aware defaults (accept types,
     max entries, max file size) derived from your schema's collection config.
  2. Renders a single `<.form>` containing a `<.live_file_input>`, drop zone,
     entry previews with progress bars, and a submit button.
  3. On submit, calls `consume_uploaded_entries/3` and persists each file via
     `PhxMediaLibrary.add/2 |> to_collection/2`.
  4. Streams existing + newly uploaded media into a gallery grid with
     delete-on-hover support.

  Because the component owns its own `<.form>`, there is no nested-form
  problem. The upload binary transfer and consumption work correctly.
  """

  use Phoenix.LiveComponent

  alias PhxMediaLibrary.{Collection, Config, Media}

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def update(assigns, socket) do
    # Apply defaults for optional attrs
    assigns =
      assigns
      |> Map.put_new(:max_file_size, nil)
      |> Map.put_new(:max_entries, nil)
      |> Map.put_new(:responsive, false)
      |> Map.put_new(:upload_label, nil)
      |> Map.put_new(:upload_sublabel, nil)
      |> Map.put_new(:compact, false)
      |> Map.put_new(:columns, 4)
      |> Map.put_new(:conversion, nil)
      |> Map.put_new(:show_gallery, true)
      |> Map.put_new(:class, nil)
      |> Map.put_new(:upload_class, nil)
      |> Map.put_new(:gallery_class, nil)
      |> Map.put_new(:button_class, nil)

    socket = assign(socket, assigns)
    collection_name = socket.assigns.collection

    # Derive a unique upload name from the component id to avoid collisions
    # when multiple MediaLive components are on the same page.
    upload_name = upload_name(socket.assigns.id)

    socket =
      if connected?(socket) && !upload_configured?(socket, upload_name) do
        model = socket.assigns.model

        upload_opts =
          build_upload_opts(model, collection_name, socket.assigns)

        socket
        |> allow_upload(upload_name, upload_opts)
        |> assign(:upload_name, upload_name)
        |> load_existing_media(model, collection_name)
      else
        socket
        |> assign_new(:upload_name, fn -> upload_name end)
        |> maybe_init_stream()
      end

    {:ok, socket}
  end

  # ===========================================================================
  # Events
  # ===========================================================================

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_upload", _params, socket) do
    %{
      model: model,
      collection: collection_name,
      upload_name: upload_name,
      responsive: responsive?
    } = socket.assigns

    results =
      consume_uploaded_entries(socket, upload_name, fn meta, entry ->
        result =
          model
          |> PhxMediaLibrary.add(upload_source(meta, entry))
          |> PhxMediaLibrary.using_filename(entry.client_name)
          |> maybe_with_responsive(responsive?)
          |> PhxMediaLibrary.to_collection(collection_name)

        case result do
          {:ok, media} -> {:ok, media}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    {successes, failures} =
      Enum.split_with(results, fn
        {:error, _} -> false
        %Media{} -> true
        _ -> true
      end)

    socket =
      Enum.reduce(successes, socket, fn media, sock ->
        stream_insert(sock, :media_items, media)
      end)

    socket =
      case failures do
        [] ->
          notify_parent(socket, {:uploaded, collection_name, successes})
          count = length(successes)

          put_flash(
            socket,
            :info,
            "#{count} file#{if count != 1, do: "s"} uploaded successfully"
          )

        [{:error, reason} | _] ->
          put_flash(socket, :error, "Upload failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("delete_media", %{"id" => id}, socket) do
    repo = Config.repo()
    collection_name = socket.assigns.collection

    case repo.get(Media, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "File not found")}

      media ->
        case Media.delete(media) do
          result when result == :ok or (is_tuple(result) and elem(result, 0) == :ok) ->
            notify_parent(socket, {:deleted, collection_name, media})

            {:noreply,
             socket
             |> stream_delete_by_dom_id(:media_items, "media-#{id}")
             |> put_flash(:info, "File deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, socket.assigns.upload_name, ref)}
  end

  # ===========================================================================
  # Template
  # ===========================================================================

  @impl true
  def render(assigns) do
    upload_name = assigns.upload_name
    upload = assigns[:uploads] && assigns.uploads[upload_name]
    entries = if upload, do: upload.entries, else: []
    entry_count = length(entries)

    grid_class =
      case assigns.columns do
        2 -> "grid-cols-1 sm:grid-cols-2"
        3 -> "grid-cols-1 sm:grid-cols-2 lg:grid-cols-3"
        5 -> "grid-cols-2 sm:grid-cols-3 lg:grid-cols-5"
        6 -> "grid-cols-3 sm:grid-cols-4 lg:grid-cols-6"
        _ -> "grid-cols-2 sm:grid-cols-3 lg:grid-cols-4"
      end

    assigns =
      assigns
      |> assign(:upload_ref, upload)
      |> assign(:entries, entries)
      |> assign(:entry_count, entry_count)
      |> assign(:grid_class, grid_class)

    ~H"""
    <div id={@id} class={["phx-media-live", @class]}>
      <%!-- Upload form --%>
      <.form
        for={%{}}
        id={"#{@id}-upload-form"}
        phx-change="validate"
        phx-submit="save_upload"
        phx-target={@myself}
        class="space-y-4"
      >
        <%!-- Label --%>
        <label
          :if={@upload_label}
          class="block text-sm font-medium text-zinc-700 dark:text-zinc-300"
        >
          {@upload_label}
        </label>

        <%!-- Drop zone --%>
        <%= if @upload_ref do %>
          <div phx-drop-target={@upload_ref.ref} class={@upload_class}>
            <%= if @compact do %>
              <._compact_zone upload={@upload_ref} sublabel={@upload_sublabel} />
            <% else %>
              <._full_zone upload={@upload_ref} sublabel={@upload_sublabel} />
            <% end %>
          </div>

          <%!-- Upload-level errors --%>
          <._upload_errors upload={@upload_ref} />

          <%!-- Entry list --%>
          <div :if={@entries != []} class="space-y-3" id={"#{@id}-entries"}>
            <._entry_row
              :for={entry <- @entries}
              entry={entry}
              upload={@upload_ref}
              myself={@myself}
              id={"#{@id}-entry-#{entry.ref}"}
            />
          </div>

          <%!-- Submit button --%>
          <button
            :if={@entries != []}
            type="submit"
            class={@button_class || [
              "w-full inline-flex items-center justify-center gap-2",
              "px-4 py-2.5 rounded-lg",
              "text-sm font-semibold text-white",
              "bg-blue-600 hover:bg-blue-700 active:bg-blue-800",
              "dark:bg-blue-500 dark:hover:bg-blue-600",
              "transition-colors duration-150",
              "focus:outline-none focus:ring-2 focus:ring-blue-500/50",
              "disabled:opacity-50 disabled:cursor-not-allowed"
            ]}
          >
            <._icon name="hero-arrow-up-tray" class="w-4 h-4" />
            Upload {@entry_count} file{if @entry_count != 1, do: "s"}
          </button>
        <% end %>
      </.form>

      <%!-- Gallery --%>
      <%= if @show_gallery do %>
        <div
          id={"#{@id}-gallery"}
          phx-update="stream"
          class={@gallery_class || [
            "mt-6 grid gap-4",
            @grid_class
          ]}
        >
          <%!-- Empty state --%>
          <div
            id={"#{@id}-gallery-empty"}
            class="hidden only:flex col-span-full items-center justify-center py-12"
          >
            <div class="text-center">
              <._icon
                name="hero-photo"
                class="w-12 h-12 mx-auto mb-3 text-zinc-300 dark:text-zinc-600"
              />
              <p class="text-sm text-zinc-500 dark:text-zinc-400">
                No files yet. Upload some above!
              </p>
            </div>
          </div>

          <%!-- Media cards --%>
          <div
            :for={{dom_id, media} <- @streams.media_items}
            id={dom_id}
            class="group relative"
          >
            <._gallery_card
              media={media}
              conversion={@conversion}
              myself={@myself}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ===========================================================================
  # Private sub-components
  # ===========================================================================

  attr(:upload, :any, required: true)
  attr(:sublabel, :string, default: nil)

  defp _full_zone(assigns) do
    ~H"""
    <label class={[
      "flex flex-col items-center justify-center w-full cursor-pointer",
      "min-h-[180px] px-6 py-10",
      "border-2 border-dashed rounded-xl",
      "transition-all duration-200 ease-in-out",
      "border-zinc-300 dark:border-zinc-600",
      "bg-zinc-50 dark:bg-zinc-900",
      "hover:border-blue-400 hover:bg-blue-50/50",
      "dark:hover:border-blue-500 dark:hover:bg-blue-950/30",
      "phx-drop-target-active:border-blue-500 phx-drop-target-active:bg-blue-50",
      "dark:phx-drop-target-active:border-blue-400 dark:phx-drop-target-active:bg-blue-950/50",
      "phx-drop-target-active:scale-[1.01]"
    ]}>
      <div class="flex flex-col items-center gap-3 pointer-events-none">
        <div class={[
          "flex items-center justify-center w-12 h-12 rounded-full",
          "bg-blue-100 text-blue-600",
          "dark:bg-blue-900/50 dark:text-blue-400",
          "transition-transform duration-200",
          "group-hover:scale-110"
        ]}>
          <._icon name="hero-arrow-up-tray" class="w-6 h-6" />
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

      <.live_file_input upload={@upload} class="sr-only" />
    </label>
    """
  end

  attr(:upload, :any, required: true)
  attr(:sublabel, :string, default: nil)

  defp _compact_zone(assigns) do
    ~H"""
    <label class={[
      "flex items-center gap-4 w-full px-4 py-3 cursor-pointer",
      "border-2 border-dashed rounded-lg",
      "transition-all duration-200 ease-in-out",
      "border-zinc-300 dark:border-zinc-600",
      "bg-zinc-50 dark:bg-zinc-900",
      "hover:border-blue-400 hover:bg-blue-50/50",
      "dark:hover:border-blue-500 dark:hover:bg-blue-950/30",
      "phx-drop-target-active:border-blue-500 phx-drop-target-active:bg-blue-50",
      "dark:phx-drop-target-active:border-blue-400 dark:phx-drop-target-active:bg-blue-950/50"
    ]}>
      <div class={[
        "flex items-center justify-center w-10 h-10 rounded-full shrink-0",
        "bg-blue-100 text-blue-600",
        "dark:bg-blue-900/50 dark:text-blue-400"
      ]}>
        <._icon name="hero-arrow-up-tray" class="w-5 h-5" />
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

      <.live_file_input upload={@upload} class="sr-only" />
    </label>
    """
  end

  attr(:entry, :any, required: true)
  attr(:upload, :any, required: true)
  attr(:myself, :any, required: true)
  attr(:id, :string, required: true)

  defp _entry_row(assigns) do
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
          <._icon name="hero-document" class="w-6 h-6 text-zinc-400 dark:text-zinc-500" />
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

        <%!-- Progress bar — always visible so users see feedback even on fast local uploads --%>
        <div :if={@entry.progress < 100} class="mt-1.5">
          <div class="w-full h-1.5 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div
              class={[
                "h-full rounded-full transition-all duration-300 ease-out",
                @entry.progress == 0 && "bg-zinc-300 dark:bg-zinc-600",
                @entry.progress > 0 && "bg-blue-500"
              ]}
              style={"width: #{max(@entry.progress, 2)}%"}
            />
          </div>
          <span :if={@entry.progress > 0} class="text-xs text-zinc-500 dark:text-zinc-400 tabular-nums">
            {@entry.progress}%
          </span>
        </div>

        <%!-- Completed indicator --%>
        <div :if={@entry.progress == 100 && @entry_errors == []} class="mt-1">
          <span class="inline-flex items-center gap-1 text-xs text-emerald-600 dark:text-emerald-400">
            <._icon name="hero-check-circle" class="w-3.5 h-3.5" />
            Ready
          </span>
        </div>

        <%!-- Per-entry errors --%>
        <div :if={@entry_errors != []} class="mt-1">
          <p
            :for={err <- @entry_errors}
            class="text-xs text-red-600 dark:text-red-400"
          >
            {translate_upload_error(err)}
          </p>
        </div>
      </div>

      <%!-- Cancel button --%>
      <button
        type="button"
        phx-click="cancel_upload"
        phx-value-ref={@entry.ref}
        phx-target={@myself}
        class={[
          "shrink-0 p-1.5 rounded-lg",
          "text-zinc-400 hover:text-red-500 hover:bg-red-50",
          "dark:text-zinc-500 dark:hover:text-red-400 dark:hover:bg-red-950/30",
          "transition-colors duration-150",
          "focus:outline-none focus:ring-2 focus:ring-red-500/40"
        ]}
        aria-label={"Cancel upload of #{@entry.client_name}"}
      >
        <._icon name="hero-x-mark" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr(:upload, :any, required: true)

  defp _upload_errors(assigns) do
    errors = Phoenix.Component.upload_errors(assigns.upload)
    assigns = assign(assigns, :errors, errors)

    ~H"""
    <div :if={@errors != []} class="space-y-1">
      <p
        :for={err <- @errors}
        class="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400"
      >
        <._icon name="hero-exclamation-circle" class="w-4 h-4 shrink-0" />
        {translate_upload_error(err)}
      </p>
    </div>
    """
  end

  attr(:media, :any, required: true)
  attr(:conversion, :atom, default: nil)
  attr(:myself, :any, required: true)

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
            src={media_url(@media, @conversion)}
            alt={@media.file_name}
            class="w-full h-full object-cover"
            loading="lazy"
          />
        <% else %>
          <div class="flex flex-col items-center gap-2">
            <div class={[
              "w-14 h-14 rounded-2xl",
              "bg-zinc-200/80 dark:bg-zinc-700",
              "flex items-center justify-center"
            ]}>
              <._icon name={file_type_icon(@media.mime_type)} class="w-7 h-7 text-zinc-500 dark:text-zinc-400" />
            </div>
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
            phx-click="delete_media"
            phx-value-id={@media.id}
            phx-target={@myself}
            data-confirm="Are you sure you want to delete this file?"
            class={[
              "p-2 rounded-full",
              "bg-white/90 text-red-600 hover:bg-red-600 hover:text-white",
              "shadow-lg",
              "transition-colors duration-150",
              "focus:outline-none focus:ring-2 focus:ring-white/50"
            ]}
            aria-label={"Delete #{@media.file_name}"}
          >
            <._icon name="hero-trash" class="w-5 h-5" />
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

  # Minimal icon component — renders hero icon via the standard Phoenix/Tailwind pattern
  attr(:name, :string, required: true)
  attr(:class, :string, default: "w-5 h-5")

  defp _icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp upload_name(component_id) do
    component_id
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> then(&:"media_upload_#{&1}")
  end

  defp upload_configured?(socket, upload_name) do
    Map.has_key?(socket.assigns[:uploads] || %{}, upload_name)
  end

  defp build_upload_opts(model, collection_name, assigns) do
    collection_config = get_collection_config(model, collection_name)

    opts = [max_file_size: 10_000_000]

    opts = maybe_put_accept(opts, collection_config)
    opts = maybe_put_max_entries(opts, collection_config)
    opts = maybe_put_max_file_size(opts, collection_config)

    # Apply explicit overrides from assigns
    opts =
      if assigns[:max_file_size] do
        Keyword.put(opts, :max_file_size, assigns.max_file_size)
      else
        opts
      end

    opts =
      if assigns[:max_entries] do
        Keyword.put(opts, :max_entries, assigns.max_entries)
      else
        opts
      end

    opts
  end

  defp load_existing_media(socket, model, collection_name) do
    media_items = PhxMediaLibrary.get_media(model, collection_name)

    socket
    |> stream_configure(:media_items, dom_id: &"media-#{&1.id}")
    |> stream(:media_items, media_items)
  end

  defp maybe_init_stream(socket) do
    if Map.has_key?(socket.assigns[:streams] || %{}, :media_items) do
      socket
    else
      socket
      |> stream_configure(:media_items, dom_id: &"media-#{&1.id}")
      |> stream(:media_items, [])
    end
  end

  defp get_collection_config(model, collection_name) do
    module = model.__struct__

    if function_exported?(module, :media_collections, 0) do
      module.media_collections()
      |> Enum.find(fn
        %Collection{name: ^collection_name} ->
          true

        %Collection{name: name} when is_atom(name) ->
          to_string(name) == to_string(collection_name)

        _ ->
          false
      end)
    else
      nil
    end
  end

  defp maybe_put_accept(opts, %Collection{accepts: accepts})
       when is_list(accepts) and accepts != [] do
    extensions = mime_types_to_extensions(accepts)
    Keyword.put(opts, :accept, extensions)
  end

  defp maybe_put_accept(opts, _collection), do: Keyword.put(opts, :accept, :any)

  defp maybe_put_max_entries(opts, %Collection{single_file: true}) do
    Keyword.put(opts, :max_entries, 1)
  end

  defp maybe_put_max_entries(opts, %Collection{max_files: max})
       when is_integer(max) and max > 0 do
    Keyword.put(opts, :max_entries, max)
  end

  defp maybe_put_max_entries(opts, _collection), do: Keyword.put_new(opts, :max_entries, 10)

  defp maybe_put_max_file_size(opts, %Collection{max_size: max_size})
       when is_integer(max_size) and max_size > 0 do
    Keyword.put(opts, :max_file_size, max_size)
  end

  defp maybe_put_max_file_size(opts, _collection), do: opts

  defp mime_types_to_extensions(mime_types) do
    Enum.flat_map(mime_types, fn mime ->
      case MIME.extensions(mime) do
        [] -> [".#{String.split(mime, "/") |> List.last()}"]
        exts -> Enum.map(exts, &".#{&1}")
      end
    end)
    |> Enum.uniq()
  end

  defp upload_source(%{path: path}, _entry), do: path

  defp maybe_with_responsive(adder, true), do: PhxMediaLibrary.with_responsive_images(adder)
  defp maybe_with_responsive(adder, false), do: adder

  defp notify_parent(socket, message) do
    send(self(), {__MODULE__, message})
    socket
  end

  defp image_entry?(%{client_type: client_type}) do
    String.starts_with?(client_type, "image/")
  end

  defp image_entry?(_), do: false

  defp image_media?(%Media{mime_type: mime_type}) when is_binary(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp image_media?(%{mime_type: mime_type}) when is_binary(mime_type) do
    String.starts_with?(mime_type, "image/")
  end

  defp image_media?(_), do: false

  defp media_url(media, conversion) do
    if conversion && Media.has_conversion?(media, conversion) do
      PhxMediaLibrary.url(media, conversion)
    else
      PhxMediaLibrary.url(media)
    end
  end

  defp file_type_icon(mime_type) do
    cond do
      String.starts_with?(mime_type, "video/") -> "hero-film"
      String.starts_with?(mime_type, "audio/") -> "hero-musical-note"
      mime_type == "application/pdf" -> "hero-document-text"
      String.contains?(mime_type, "spreadsheet") -> "hero-table-cells"
      String.contains?(mime_type, "presentation") -> "hero-presentation-chart-bar"
      String.contains?(mime_type, "zip") -> "hero-archive-box"
      String.contains?(mime_type, "compressed") -> "hero-archive-box"
      true -> "hero-document"
    end
  end

  defp file_extension(filename) when is_binary(filename) do
    filename |> Path.extname() |> String.trim_leading(".")
  end

  defp file_extension(_), do: ""

  defp format_file_size(nil), do: ""

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> format_unit(bytes, 1_000_000_000, "GB")
      bytes >= 1_000_000 -> format_unit(bytes, 1_000_000, "MB")
      bytes >= 1_000 -> format_unit(bytes, 1_000, "KB")
      true -> "#{bytes} B"
    end
  end

  defp format_unit(bytes, divisor, unit) do
    value = bytes / divisor
    formatted = :erlang.float_to_binary(Float.round(value, 1), decimals: 1)
    "#{formatted} #{unit}"
  end

  defp translate_upload_error(:too_large), do: "File is too large"
  defp translate_upload_error(:too_many_files), do: "Too many files"
  defp translate_upload_error(:not_accepted), do: "File type not accepted"
  defp translate_upload_error(:external_client_failure), do: "Upload failed"
  defp translate_upload_error({:too_large, _}), do: "File is too large"
  defp translate_upload_error({:not_accepted, _}), do: "File type not accepted"

  defp translate_upload_error({error, _detail}) when is_atom(error) do
    error |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp translate_upload_error(other), do: inspect(other)
end
