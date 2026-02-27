defmodule PhxMediaLibrary.HasMedia.DSL do
  @moduledoc """
  Provides the `media_collections do ... end` and `media_conversions do ... end`
  declarative macros for defining media configuration at compile time.

  These macros are automatically imported when you `use PhxMediaLibrary.HasMedia`.
  You don't need to use this module directly.

  ## Examples

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
          convert :thumb, width: 150, height: 150, fit: :cover
          convert :preview, width: 800, quality: 85
          convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
        end
      end

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

  ## Examples

      media_collections do
        collection :images, disk: :s3, max_files: 20
        collection :documents, accepts: ~w(application/pdf text/plain)
        collection :avatar, single_file: true, fallback_url: "/images/default.png"
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

  ## Examples

      media_conversions do
        convert :thumb, width: 150, height: 150, fit: :cover
        convert :preview, width: 800, quality: 85
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
