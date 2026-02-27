defmodule PhxMediaLibrary.HasMedia.DSL.CollectionAccumulator do
  @moduledoc false
  # Internal module that provides `collection/1` and `collection/2` macros
  # which accumulate into the `@__phx_media_collections__` attribute during
  # the `media_collections do ... end` block.

  defmacro collection(name, opts \\ []) do
    quote do
      @__phx_media_collections__ PhxMediaLibrary.Collection.new(
                                   unquote(name),
                                   unquote(opts)
                                 )
    end
  end
end
