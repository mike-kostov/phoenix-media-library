defmodule PhxMediaLibrary.LiveUpload do
  @moduledoc """
  Provides upload helpers for Phoenix LiveViews.

  `use PhxMediaLibrary.LiveUpload` injects convenience functions into your
  LiveView for managing media uploads backed by `PhxMediaLibrary`.

  ## Usage

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
               |> put_flash(:info, "Uploaded \#{length(media_items)} file(s)")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Upload failed: \#{inspect(reason)}")}
          end
        end

        def handle_event("delete_media", %{"id" => id}, socket) do
          case delete_media_by_id(id, notify: self()) do
            :ok -> {:noreply, stream_delete_by_dom_id(socket, :media, "media-\#{id}")}
            {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
          end
        end

        def handle_event("cancel_upload", %{"ref" => ref}, socket) do
          {:noreply, cancel_upload(socket, :images, ref)}
        end

        # Handle media lifecycle notifications
        def handle_info({:media_added, media_items}, socket) do
          # React to newly added media (e.g. update counters, trigger side-effects)
          {:noreply, assign(socket, :media_count, length(media_items))}
        end

        def handle_info({:media_removed, _media}, socket) do
          {:noreply, socket}
        end

        def handle_info({:media_error, _reason}, socket) do
          {:noreply, socket}
        end
      end

  ## How It Works

  The module provides three categories of helpers:

  ### 1. Setup Helpers

  - `allow_media_upload/3` — wraps `Phoenix.LiveView.allow_upload/3` with
    collection-aware defaults. Automatically derives `:accept`, `:max_entries`,
    and `:max_file_size` from the collection configuration.

  - `stream_existing_media/4` — loads existing media for a model/collection
    and streams them into a LiveView stream for display.

  ### 2. Consumption Helpers

  - `consume_media/4` — wraps `Phoenix.LiveView.consume_uploaded_entries/3`
    and calls `PhxMediaLibrary.add/2 |> PhxMediaLibrary.to_collection/2` for
    each completed upload entry.

  ### 3. Management Helpers

  - `stream_media_items/3` — inserts newly created media items into an
    existing stream so the UI updates without a full reload.

  - `delete_media_by_id/1` — fetches a media record by ID and deletes it
    along with its files.

  - `media_upload_errors/2` — returns human-readable error strings for an
    upload's errors.

  - `media_entry_errors/2` — returns human-readable error strings for a
    specific upload entry.

  ## Event Notifications

  Both `consume_media/5` and `delete_media_by_id/2` accept a `:notify`
  option. When set to a pid (e.g. `self()`), lifecycle messages are sent
  to that process:

  - `{:media_added, [Media.t()]}` — after successful upload consumption
  - `{:media_error, reason}` — when upload consumption fails
  - `{:media_removed, Media.t()}` — after successful media deletion

  This allows parent LiveViews (or any process) to react to media
  lifecycle events via `handle_info/2`.
  """

  alias PhxMediaLibrary.{Collection, Config, Media}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import PhxMediaLibrary.LiveUpload
    end
  end

  # ---------------------------------------------------------------------------
  # Setup helpers
  # ---------------------------------------------------------------------------

  @doc """
  Allows a media upload on the socket with collection-aware defaults.

  Wraps `Phoenix.LiveView.allow_upload/3`, automatically deriving the
  `:accept`, `:max_entries`, and `:max_file_size` options from the
  collection configuration defined on the model's schema.

  ## Options

  All options are passed through to `allow_upload/3`. The following are
  specific to `allow_media_upload/3`:

  - `:model` — (required) the Ecto struct that owns the media. Used to
    look up collection configuration.
  - `:collection` — (required) the collection atom to upload into.
  - `:accept` — override the accept list. When not provided, it is
    derived from the collection's `:accepts` MIME types. Falls back to
    `:any` when the collection has no type restrictions.
  - `:max_entries` — override maximum entries. Derived from the
    collection's `:max_files` or `:single_file` setting.
  - `:max_file_size` — maximum file size in bytes. Defaults to 10 MB.

  Any other option (e.g. `:auto_upload`, `:chunk_size`, `:progress`) is
  forwarded to `allow_upload/3` unchanged.

  ## Examples

      # Derive everything from collection config
      allow_media_upload(socket, :images, model: post, collection: :images)

      # Override accept and max entries
      allow_media_upload(socket, :avatar,
        model: user,
        collection: :avatar,
        accept: ~w(.jpg .png),
        max_entries: 1
      )
  """
  @spec allow_media_upload(Phoenix.LiveView.Socket.t(), atom(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def allow_media_upload(socket, name, opts) do
    {model, opts} = Keyword.pop!(opts, :model)
    {collection_name, opts} = Keyword.pop!(opts, :collection)

    collection_config = get_collection_config(model, collection_name)

    upload_opts =
      opts
      |> maybe_put_accept(collection_config)
      |> maybe_put_max_entries(collection_config)
      |> maybe_put_max_file_size(collection_config)

    Phoenix.LiveView.allow_upload(socket, name, upload_opts)
  end

  @doc """
  Loads existing media for a model/collection and streams them.

  This is a convenience that queries existing media and feeds them into
  a LiveView stream so they can be rendered alongside new uploads.

  The stream is configured with a `:dom_id` function that prefixes each
  item's ID with `"media-"`.

  ## Examples

      socket
      |> stream_existing_media(:media, post, :images)

      # Renders in template as @streams.media
  """
  @spec stream_existing_media(
          Phoenix.LiveView.Socket.t(),
          atom(),
          Ecto.Schema.t(),
          atom()
        ) :: Phoenix.LiveView.Socket.t()
  def stream_existing_media(socket, stream_name, model, collection_name) do
    media_items = PhxMediaLibrary.get_media(model, collection_name)

    socket
    |> Phoenix.LiveView.stream_configure(stream_name,
      dom_id: &"media-#{&1.id}"
    )
    |> Phoenix.LiveView.stream(stream_name, media_items)
  end

  # ---------------------------------------------------------------------------
  # Consumption helpers
  # ---------------------------------------------------------------------------

  @doc """
  Consumes completed uploads and persists them as media via PhxMediaLibrary.

  Wraps `Phoenix.LiveView.consume_uploaded_entries/3`. For each completed
  entry, it calls `PhxMediaLibrary.add/2 |> PhxMediaLibrary.to_collection/2`
  to store the file and create the database record.

  Returns `{:ok, [Media.t()]}` with all successfully created media items,
  or `{:error, reason}` if any entry fails (already-consumed entries are
  still persisted — the error is for the first failure encountered).

  ## Options

  - `:disk` — override the storage disk for these uploads.
  - `:custom_properties` — a map of custom properties to attach to each
    media item.
  - `:responsive` — whether to generate responsive images. Defaults to
    `false`.
  - `:notify` — a pid to send lifecycle messages to. When set, sends
    `{:media_added, media_items}` on success or `{:media_error, reason}`
    on failure.

  ## Examples

      {:ok, media_items} = consume_media(socket, :images, post, :images)

      {:ok, media_items} =
        consume_media(socket, :images, post, :images,
          custom_properties: %{"uploaded_by" => user.id},
          responsive: true,
          notify: self()
        )
  """
  @spec consume_media(
          Phoenix.LiveView.Socket.t(),
          atom(),
          Ecto.Schema.t(),
          atom(),
          keyword()
        ) :: {:ok, [Media.t()]} | {:error, term()}
  def consume_media(socket, upload_name, model, collection_name, opts \\ []) do
    disk = Keyword.get(opts, :disk)
    custom_properties = Keyword.get(opts, :custom_properties, %{})
    responsive? = Keyword.get(opts, :responsive, false)
    notify_pid = Keyword.get(opts, :notify)

    results =
      Phoenix.LiveView.consume_uploaded_entries(socket, upload_name, fn meta, entry ->
        result =
          model
          |> PhxMediaLibrary.add(upload_source(meta, entry))
          |> PhxMediaLibrary.using_filename(entry.client_name)
          |> maybe_with_custom_properties(custom_properties)
          |> maybe_with_responsive(responsive?)
          |> PhxMediaLibrary.to_collection(collection_name, disk_opts(disk))

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

    case failures do
      [] ->
        maybe_notify(notify_pid, {:media_added, successes})
        {:ok, successes}

      [{:error, reason} | _] ->
        maybe_notify(notify_pid, {:media_error, reason})
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Management helpers
  # ---------------------------------------------------------------------------

  @doc """
  Inserts newly created media items into an existing stream.

  Use this after `consume_media/5` to update the UI without reloading.

  ## Examples

      {:ok, media_items} = consume_media(socket, :images, post, :images)
      socket = stream_media_items(socket, :media, media_items)
  """
  @spec stream_media_items(Phoenix.LiveView.Socket.t(), atom(), [Media.t()]) ::
          Phoenix.LiveView.Socket.t()
  def stream_media_items(socket, stream_name, media_items) when is_list(media_items) do
    Enum.reduce(media_items, socket, fn media, sock ->
      Phoenix.LiveView.stream_insert(sock, stream_name, media)
    end)
  end

  @doc """
  Deletes a media item by its ID and removes its files from storage.

  Returns `:ok` on success, `{:error, :not_found}` if the media doesn't
  exist, or `{:error, reason}` on failure.

  ## Options

  - `:notify` — a pid to send `{:media_removed, media}` to on success.

  ## Examples

      case delete_media_by_id(media_id) do
        :ok -> {:noreply, stream_delete_by_dom_id(socket, :media, "media-\#{media_id}")}
        {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
      end

      # With notification
      case delete_media_by_id(media_id, notify: self()) do
        :ok -> {:noreply, stream_delete_by_dom_id(socket, :media, "media-\#{media_id}")}
        {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
      end
  """
  @spec delete_media_by_id(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_media_by_id(id, opts \\ []) do
    repo = Config.repo()
    notify_pid = Keyword.get(opts, :notify)

    case repo.get(Media, id) do
      nil ->
        {:error, :not_found}

      media ->
        case Media.delete(media) do
          :ok ->
            maybe_notify(notify_pid, {:media_removed, media})
            :ok

          error ->
            error
        end
    end
  end

  @doc """
  Returns human-readable error strings for an upload.

  Translates the error atoms returned by `Phoenix.Component.upload_errors/1`
  into user-friendly messages.

  ## Examples

      for msg <- media_upload_errors(@uploads.images) do
        ...
      end
  """
  @spec media_upload_errors(Phoenix.LiveView.UploadConfig.t()) :: [String.t()]
  def media_upload_errors(%{errors: errors}) do
    Enum.map(errors, &translate_upload_error/1)
  end

  def media_upload_errors(_), do: []

  @doc """
  Returns human-readable error strings for a specific upload entry.

  Translates the error atoms returned by `Phoenix.Component.upload_errors/2`
  into user-friendly messages.

  ## Examples

      for entry <- @uploads.images.entries do
        for msg <- media_entry_errors(@uploads.images, entry) do
          ...
        end
      end
  """
  @spec media_entry_errors(Phoenix.LiveView.UploadConfig.t(), Phoenix.LiveView.UploadEntry.t()) ::
          [String.t()]
  def media_entry_errors(upload_config, entry) do
    upload_config
    |> Phoenix.Component.upload_errors(entry)
    |> Enum.map(&translate_upload_error/1)
  end

  # ---------------------------------------------------------------------------
  # Introspection helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns whether the upload has any entries (pending or completed).

  Useful for conditionally showing/hiding UI elements.

  ## Examples

      <div :if={has_upload_entries?(@uploads.images)}>
        ...upload preview area...
      </div>
  """
  @spec has_upload_entries?(Phoenix.LiveView.UploadConfig.t()) :: boolean()
  def has_upload_entries?(%{entries: entries}), do: entries != []
  def has_upload_entries?(_), do: false

  @doc """
  Returns whether an upload entry is an image based on its client MIME type.

  Useful for conditionally showing image previews vs. file icons.

  ## Examples

      <%= if image_entry?(entry) do %>
        <.live_img_preview entry={entry} />
      <% else %>
        <.icon name="hero-document" />
      <% end %>
  """
  @spec image_entry?(Phoenix.LiveView.UploadEntry.t()) :: boolean()
  def image_entry?(%{client_type: client_type}) do
    String.starts_with?(client_type, "image/")
  end

  def image_entry?(_), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_collection_config(model, collection_name) do
    if function_exported?(model.__struct__, :get_media_collection, 1) do
      model.__struct__.get_media_collection(collection_name)
    else
      nil
    end
  end

  defp maybe_put_accept(opts, %Collection{accepts: accepts})
       when is_list(accepts) and accepts != [] do
    Keyword.put_new(opts, :accept, mime_types_to_extensions(accepts))
  end

  defp maybe_put_accept(opts, _collection) do
    Keyword.put_new(opts, :accept, :any)
  end

  defp maybe_put_max_entries(opts, %Collection{single_file: true}) do
    Keyword.put_new(opts, :max_entries, 1)
  end

  defp maybe_put_max_entries(opts, %Collection{max_files: max}) when is_integer(max) do
    Keyword.put_new(opts, :max_entries, max)
  end

  defp maybe_put_max_entries(opts, _collection) do
    Keyword.put_new(opts, :max_entries, 20)
  end

  defp maybe_put_max_file_size(opts, %Collection{max_size: max_size})
       when is_integer(max_size) and max_size > 0 do
    Keyword.put_new(opts, :max_file_size, max_size)
  end

  defp maybe_put_max_file_size(opts, _collection) do
    Keyword.put_new(opts, :max_file_size, 10_000_000)
  end

  defp mime_types_to_extensions(mime_types) do
    Enum.flat_map(mime_types, fn mime ->
      case MIME.extensions(mime) do
        [] ->
          # If no extensions found, pass the MIME type as-is.
          # Phoenix allow_upload also accepts MIME types like "image/*"
          [mime]

        extensions ->
          Enum.map(extensions, &".#{&1}")
      end
    end)
    |> Enum.uniq()
  end

  defp upload_source(%{path: path}, _entry), do: path

  defp maybe_with_custom_properties(adder, props) when map_size(props) == 0, do: adder

  defp maybe_with_custom_properties(adder, props) do
    PhxMediaLibrary.with_custom_properties(adder, props)
  end

  defp maybe_with_responsive(adder, false), do: adder
  defp maybe_with_responsive(adder, true), do: PhxMediaLibrary.with_responsive_images(adder)

  defp disk_opts(nil), do: []
  defp disk_opts(disk), do: [disk: disk]

  defp maybe_notify(nil, _message), do: :ok
  defp maybe_notify(pid, message) when is_pid(pid), do: send(pid, message)

  @doc """
  Translates an upload error atom into a human-readable string.

  Override this function in your own module if you need custom messages
  or i18n support.

  ## Examples

      translate_upload_error(:too_large)
      #=> "File is too large"
  """
  @spec translate_upload_error(atom() | {atom(), term()}) :: String.t()
  def translate_upload_error(:too_large), do: "File is too large"
  def translate_upload_error(:too_many_files), do: "Too many files selected"
  def translate_upload_error(:not_accepted), do: "File type is not accepted"
  def translate_upload_error(:external_client_failure), do: "Upload failed — please try again"

  def translate_upload_error({:too_large, _}), do: "File is too large"
  def translate_upload_error({:not_accepted, _}), do: "File type is not accepted"

  def translate_upload_error(error) when is_atom(error) do
    error
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def translate_upload_error({error, _detail}) when is_atom(error) do
    translate_upload_error(error)
  end

  def translate_upload_error(other), do: "Upload error: #{inspect(other)}"
end
