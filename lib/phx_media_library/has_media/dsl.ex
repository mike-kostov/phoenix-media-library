defmodule PhxMediaLibrary.HasMedia.DSL do
  @moduledoc """
  Provides the `media_collections do ... end` and `media_conversions do ... end`
  declarative macros for defining media configuration at compile time.

  These macros are automatically imported when you `use PhxMediaLibrary.HasMedia`.
  You don't need to use this module directly.

  ## Examples

  ### Flat style (collections and conversions separate)

      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          has_media()
          timestamps()
        end

        media_collections do
          collection :images, disk: :s3, max_files: 20
          collection :documents, accepts: ~w(application/pdf)
          collection :avatar, single_file: true
        end

        media_conversions do
          convert :thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]
          convert :preview, width: 800, quality: 85, collections: [:images]
          convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
        end
      end

  ### Nested style (conversions inside collections)

  You can nest `convert` calls inside a `collection ... do ... end` block.
  Each conversion is automatically scoped to the enclosing collection —
  no need to pass `:collections` manually:

      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          has_media()
          timestamps()
        end

        media_collections do
          collection :images, max_files: 20 do
            convert :thumb, width: 150, height: 150, fit: :cover
            convert :preview, width: 800, quality: 85
            convert :banner, width: 1200, height: 400, fit: :crop
          end

          collection :documents, accepts: ~w(application/pdf)

          collection :avatar, single_file: true do
            convert :thumb, width: 150, height: 150, fit: :cover
          end
        end
      end

  The nested style makes it immediately clear which conversions apply to
  which collections. Collections without image content (like `:documents`)
  simply omit the `do` block — no conversions will run for those uploads.

  You can also mix both styles: use nested conversions for some collections
  and a separate `media_conversions do ... end` block for shared conversions.

  The DSL and function-based styles are **mutually exclusive** for each
  concern. If you use `media_collections do ... end`, don't also define
  `def media_collections`. The DSL block will override any previous
  function definition.
  """

  @doc """
  Declare media collections using a block syntax.

  Inside the block, call `collection/1` or `collection/2` to register
  each collection. The collections are accumulated at compile time and
  injected as the `media_collections/0` function via `@before_compile`.

  Collections can optionally accept a `do` block containing `convert`
  calls. Conversions defined inside the block are automatically scoped
  to the enclosing collection.

  ## Examples

  Simple collections (no nested conversions):

      media_collections do
        collection :images, disk: :s3, max_files: 20
        collection :documents, accepts: ~w(application/pdf text/plain)
        collection :avatar, single_file: true, fallback_url: "/images/default.png"
      end

  Nested conversions (auto-scoped to the collection):

      media_collections do
        collection :images, max_files: 20 do
          convert :thumb, width: 150, height: 150, fit: :cover
          convert :preview, width: 800, quality: 85
        end

        collection :documents, accepts: ~w(application/pdf)

        collection :avatar, single_file: true do
          convert :thumb, width: 150, height: 150, fit: :cover
        end
      end

  """
  defmacro media_collections(do: block) do
    quote do
      Module.put_attribute(__MODULE__, :__phx_media_collections_dsl__, true)

      # Clear the conflicting function imports from HasMedia before
      # importing the accumulator macros with the same names.
      import PhxMediaLibrary.HasMedia,
        only: [
          has_media: 0,
          has_media: 1,
          conversion: 2,
          convert: 2
        ]

      import PhxMediaLibrary.HasMedia.DSL, only: []
      import PhxMediaLibrary.HasMedia.DSL.CollectionAccumulator

      unquote(block)

      # Restore normal imports after the block
      import PhxMediaLibrary.HasMedia.DSL.CollectionAccumulator, only: []

      import PhxMediaLibrary.HasMedia,
        only: [
          has_media: 0,
          has_media: 1,
          collection: 1,
          collection: 2,
          conversion: 2,
          convert: 2
        ]

      import PhxMediaLibrary.HasMedia.DSL,
        only: [media_collections: 1, media_conversions: 1]
    end
  end

  @doc """
  Declare media conversions using a block syntax.

  Inside the block, call `convert/2` to register each conversion.
  The conversions are accumulated at compile time and injected as the
  `media_conversions/0` function via `@before_compile`.

  > **Important:** Always use the `:collections` option to scope conversions
  > to the collections they apply to. Without it, the conversion runs for
  > **every** collection — including non-image collections like documents,
  > which will cause processing errors. If you prefer to scope conversions
  > visually, use the nested `collection ... do convert ... end` syntax
  > in `media_collections` instead.

  ## Examples

      media_conversions do
        # Scoped to specific collections — recommended
        convert :thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]
        convert :preview, width: 800, quality: 85, collections: [:images]
        convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
      end

  """
  defmacro media_conversions(do: block) do
    quote do
      Module.put_attribute(__MODULE__, :__phx_media_conversions_dsl__, true)

      # Clear the conflicting function imports from HasMedia before
      # importing the accumulator macros with the same names.
      import PhxMediaLibrary.HasMedia,
        only: [
          has_media: 0,
          has_media: 1,
          collection: 1,
          collection: 2
        ]

      import PhxMediaLibrary.HasMedia.DSL, only: []
      import PhxMediaLibrary.HasMedia.DSL.ConversionAccumulator

      unquote(block)

      # Restore normal imports after the block
      import PhxMediaLibrary.HasMedia.DSL.ConversionAccumulator, only: []

      import PhxMediaLibrary.HasMedia,
        only: [
          has_media: 0,
          has_media: 1,
          collection: 1,
          collection: 2,
          conversion: 2,
          convert: 2
        ]

      import PhxMediaLibrary.HasMedia.DSL,
        only: [media_collections: 1, media_conversions: 1]
    end
  end
end
