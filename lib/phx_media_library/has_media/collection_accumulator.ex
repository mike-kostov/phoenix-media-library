defmodule PhxMediaLibrary.HasMedia.DSL.CollectionAccumulator do
  @moduledoc false
  # Internal module that provides `collection/1`, `collection/2`, and
  # `collection/3` macros which accumulate into the
  # `@__phx_media_collections__` attribute during the
  # `media_collections do ... end` block.
  #
  # The block variant accepts a `do` block containing `convert` calls.
  # Each conversion defined inside the block is automatically scoped
  # to the enclosing collection (the `:collections` option is injected).
  #
  # ## Usage
  #
  #     media_collections do
  #       # Simple collection (no conversions)
  #       collection :documents, accepts: ~w(application/pdf)
  #
  #       # Collection with nested conversions (auto-scoped)
  #       collection :photos, accepts: ~w(image/jpeg image/png) do
  #         convert :thumb, width: 150, height: 150, fit: :cover
  #       end
  #
  #       # Collection with opts AND nested conversions
  #       collection :gallery, max_files: 20 do
  #         convert :preview, width: 800
  #       end
  #     end

  @doc false
  defmacro collection(name) do
    quote do
      @__phx_media_collections__ PhxMediaLibrary.Collection.new(unquote(name), [])
    end
  end

  @doc false
  defmacro collection(name, opts_or_do) do
    # `collection :photos do ... end` is parsed as
    # `collection(:photos, [do: block])` — a keyword list with a `:do` key.
    #
    # `collection :photos, accepts: ~w(image/jpeg)` is also a keyword list
    # but without a `:do` key.
    case Keyword.pop(opts_or_do, :do) do
      {nil, opts} ->
        # No do block — plain collection with options
        quote do
          @__phx_media_collections__ PhxMediaLibrary.Collection.new(
                                       unquote(name),
                                       unquote(opts)
                                     )
        end

      {block, []} ->
        # `collection :name do ... end` — block only, no extra opts
        build_collection_with_block(name, [], block)

      {block, opts} ->
        # `collection :name, opt: val do ... end` — opts + block
        build_collection_with_block(name, opts, block)
    end
  end

  @doc false
  defmacro collection(name, opts, do: block) do
    # Explicit 3-arg form: `collection :name, [opts], do: block`
    build_collection_with_block(name, opts, block)
  end

  defp build_collection_with_block(name, opts, block) do
    quote do
      # Register the collection itself
      @__phx_media_collections__ PhxMediaLibrary.Collection.new(
                                   unquote(name),
                                   unquote(opts)
                                 )

      # Temporarily store the current collection name so nested
      # `convert` calls can auto-scope to it.
      @__phx_media_current_collection__ unquote(name)

      # Mark conversions DSL as used so __before_compile__ injects
      # media_conversions/0 from the accumulated attributes.
      Module.put_attribute(__MODULE__, :__phx_media_conversions_dsl__, true)

      # Clear convert/conversion imports from HasMedia to avoid ambiguity
      # with the nested accumulator's versions.
      import PhxMediaLibrary.HasMedia,
        only: [
          has_media: 0,
          has_media: 1
        ]

      import PhxMediaLibrary.HasMedia.DSL.NestedConversionAccumulator

      unquote(block)

      # Restore imports after the block: clear the nested conversion
      # macros and bring back convert/conversion from HasMedia.
      # We do NOT re-import collection from HasMedia because
      # CollectionAccumulator is still active in the enclosing
      # media_collections block.
      import PhxMediaLibrary.HasMedia.DSL.NestedConversionAccumulator, only: []

      import PhxMediaLibrary.HasMedia,
        only: [
          has_media: 0,
          has_media: 1,
          conversion: 2,
          convert: 2
        ]

      # Clear the current collection marker
      @__phx_media_current_collection__ nil
    end
  end
end
