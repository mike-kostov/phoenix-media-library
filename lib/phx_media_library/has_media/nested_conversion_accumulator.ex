defmodule PhxMediaLibrary.HasMedia.DSL.NestedConversionAccumulator do
  @moduledoc false
  # Internal module that provides `convert/2` and `conversion/2` macros for
  # use inside a `collection ... do ... end` block.
  #
  # Unlike the top-level `ConversionAccumulator`, these macros automatically
  # inject the enclosing collection name into the conversion's `:collections`
  # option. This means:
  #
  #     media_collections do
  #       collection :photos, accepts: ~w(image/jpeg) do
  #         convert :thumb, width: 150, height: 150, fit: :cover
  #       end
  #     end
  #
  # is equivalent to:
  #
  #     media_conversions do
  #       convert :thumb, width: 150, height: 150, fit: :cover, collections: [:photos]
  #     end
  #
  # If the developer explicitly passes a `:collections` option inside the
  # nested block, the explicit value is respected and the auto-scoping is
  # skipped. This check happens at macro expansion time (not runtime).

  @doc false
  defmacro convert(name, opts) do
    if Keyword.has_key?(opts, :collections) do
      # Developer explicitly scoped — respect their choice
      quote do
        @__phx_media_conversions__ PhxMediaLibrary.Conversion.new(
                                     unquote(name),
                                     unquote(opts)
                                   )
      end
    else
      # Auto-scope to the enclosing collection
      quote do
        merged_opts =
          Keyword.put(unquote(opts), :collections, [@__phx_media_current_collection__])

        @__phx_media_conversions__ PhxMediaLibrary.Conversion.new(
                                     unquote(name),
                                     merged_opts
                                   )
      end
    end
  end

  @doc false
  defmacro conversion(name, opts) do
    if Keyword.has_key?(opts, :collections) do
      # Developer explicitly scoped — respect their choice
      quote do
        @__phx_media_conversions__ PhxMediaLibrary.Conversion.new(
                                     unquote(name),
                                     unquote(opts)
                                   )
      end
    else
      # Auto-scope to the enclosing collection
      quote do
        merged_opts =
          Keyword.put(unquote(opts), :collections, [@__phx_media_current_collection__])

        @__phx_media_conversions__ PhxMediaLibrary.Conversion.new(
                                     unquote(name),
                                     merged_opts
                                   )
      end
    end
  end
end
