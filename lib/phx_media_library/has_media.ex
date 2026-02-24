defmodule PhxMediaLibrary.HasMedia do
  @moduledoc """
  Adds media association capabilities to an Ecto schema.

  ## Usage

      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          has_media()
          timestamps()
        end

        # Optional: Define collections with specific settings
        def media_collections do
          [
            collection(:images, disk: :local),
            collection(:documents, accepts: ~w(application/pdf)),
            collection(:avatar, single_file: true)
          ]
        end

        # Optional: Define image conversions
        def media_conversions do
          [
            conversion(:thumb, width: 150, height: 150, fit: :cover),
            conversion(:preview, width: 800, quality: 85)
          ]
        end
      end

  ## Collection Options

  - `:disk` - Storage disk to use (default: configured default)
  - `:accepts` - List of accepted MIME types
  - `:single_file` - Only keep one file in collection (default: false)
  - `:max_files` - Maximum number of files to keep
  - `:fallback_url` - URL to use when collection is empty

  ## Conversion Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - How to fit the image (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - JPEG/WebP quality (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`)
  - `:collections` - Only apply to specific collections

  """

  alias PhxMediaLibrary.{Collection, Conversion}

  defmacro __using__(_opts) do
    quote do
      import PhxMediaLibrary.HasMedia, only: [has_media: 0, has_media: 1, collection: 1, collection: 2, conversion: 2]

      @before_compile PhxMediaLibrary.HasMedia

      # Default implementations that can be overridden
      def media_collections, do: []
      def media_conversions, do: []

      defoverridable media_collections: 0, media_conversions: 0
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Get the collection configuration for this model.
      """
      def get_media_collection(name) do
        media_collections()
        |> Enum.find(fn %Collection{name: n} -> n == name end)
      end

      @doc """
      Get all conversion configurations for this model.
      """
      def get_media_conversions(collection_name \\ nil) do
        conversions = media_conversions()

        if collection_name do
          Enum.filter(conversions, fn %Conversion{collections: cols} ->
            cols == [] or collection_name in cols
          end)
        else
          conversions
        end
      end
    end
  end

  @doc """
  Declares that this schema has media associations.

  This is a marker macro that can be used in the schema block.
  Currently a no-op but allows for future field injection if needed.
  """
  defmacro has_media(opts \\ []) do
    quote do
      # Placeholder for potential future field injection
      # For now, media is stored in a separate table with polymorphic association
      _ = unquote(opts)
    end
  end

  @doc """
  Define a media collection.
  """
  def collection(name, opts \\ []) do
    Collection.new(name, opts)
  end

  @doc """
  Define a media conversion.
  """
  def conversion(name, opts) do
    Conversion.new(name, opts)
  end
end
