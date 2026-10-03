defmodule PhxMediaLibrary.Model do
  @moduledoc """
  Reads media settings from a model — an Ecto schema that `use`s
  `PhxMediaLibrary.HasMedia` — and keeps its collections within their limits.

  This is the one place that knows how to get a model's mediable type,
  collection and conversion definitions and default disk, so the different
  ways of adding media (`MediaAdder`, direct uploads, LiveView helpers)
  agree with each other.
  """

  import Ecto.Query, only: [from: 2]

  alias PhxMediaLibrary.{Collection, Config, Conversion, Media}

  @doc """
  The polymorphic type stored in `mediable_type` for this model.

  Uses `__media_type__/0` from `HasMedia` (the table name by default). For
  other schemas it falls back to the Ecto table name, then to the
  underscored module name.

  ## Examples

      PhxMediaLibrary.Model.mediable_type(%MyApp.Post{})
      #=> "posts"

  """
  @spec mediable_type(Ecto.Schema.t() | struct()) :: String.t()
  def mediable_type(%module{}) do
    cond do
      function_exported?(module, :__media_type__, 0) -> module.__media_type__()
      function_exported?(module, :__schema__, 1) -> module.__schema__(:source)
      true -> module |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  @doc """
  The collection definition for `collection_name` (atom or string), or `nil`
  when the model doesn't define it.

  ## Examples

      PhxMediaLibrary.Model.collection(post, :images)
      #=> %PhxMediaLibrary.Collection{name: :images, ...}

  """
  @spec collection(struct(), atom() | String.t()) :: Collection.t() | nil
  def collection(%module{}, collection_name) do
    if function_exported?(module, :media_collections, 0) do
      name = to_string(collection_name)
      Enum.find(module.media_collections(), &(to_string(&1.name) == name))
    end
  end

  @doc """
  The conversions that apply to `collection_name`.

  ## Examples

      PhxMediaLibrary.Model.conversions(post, :images)
      #=> [%PhxMediaLibrary.Conversion{name: :thumb, ...}]

  """
  @spec conversions(struct(), atom()) :: [Conversion.t()]
  def conversions(%module{}, collection_name) do
    if function_exported?(module, :get_media_conversions, 1) do
      module.get_media_conversions(collection_name)
    else
      []
    end
  end

  @doc """
  The disk for `collection_name`: the collection's `disk:` setting, or the
  configured default disk.

  ## Examples

      PhxMediaLibrary.Model.default_disk(post, :images)
      #=> :local

  """
  @spec default_disk(struct(), atom()) :: atom() | String.t()
  def default_disk(model, collection_name) do
    case collection(model, collection_name) do
      %Collection{disk: disk} when not is_nil(disk) -> disk
      _ -> Config.default_disk()
    end
  end

  @doc """
  The `order_column` for the next media added to a collection.

  ## Examples

      PhxMediaLibrary.Model.next_order(post, :images)
      #=> 4

  """
  @spec next_order(struct(), atom() | String.t()) :: pos_integer()
  def next_order(model, collection_name) do
    type = mediable_type(model)
    collection_name = to_string(collection_name)

    query =
      from(m in Media,
        where: m.mediable_type == ^type,
        where: m.mediable_id == ^model.id,
        where: m.collection_name == ^collection_name,
        select: max(m.order_column)
      )

    (Config.repo().one(query) || 0) + 1
  end

  @doc """
  Apply a collection's `single_file` and `max_files` limits after
  `new_media` was added, deleting the oldest media beyond the limit.

  Deletion goes through `Media.delete/1`, so it respects soft deletes.

  ## Examples

      :ok = PhxMediaLibrary.Model.enforce_collection_limits(post, :avatar, media)

  """
  @spec enforce_collection_limits(struct(), atom(), Media.t()) :: :ok
  def enforce_collection_limits(model, collection_name, %Media{} = new_media) do
    case collection(model, collection_name) do
      %Collection{single_file: true} ->
        model
        |> Media.for_model(collection_name)
        |> Enum.reject(&(&1.id == new_media.id))
        |> Enum.each(&Media.delete/1)

      %Collection{max_files: max} when is_integer(max) and max > 0 ->
        # Ordered oldest first; keep the newest `max`.
        model
        |> Media.for_model(collection_name)
        |> Enum.drop(-max)
        |> Enum.each(&Media.delete/1)

      _ ->
        :ok
    end
  end
end
