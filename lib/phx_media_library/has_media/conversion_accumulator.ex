defmodule PhxMediaLibrary.HasMedia.DSL.ConversionAccumulator do
  @moduledoc false
  # Internal module that provides `convert/2` and `conversion/2` macros
  # which accumulate into the `@__phx_media_conversions__` attribute during
  # the `media_conversions do ... end` block.

  defmacro convert(name, opts) do
    quote do
      @__phx_media_conversions__ PhxMediaLibrary.Conversion.new(
                                   unquote(name),
                                   unquote(opts)
                                 )
    end
  end

  # Also allow `conversion` inside the block for consistency
  defmacro conversion(name, opts) do
    quote do
      @__phx_media_conversions__ PhxMediaLibrary.Conversion.new(
                                   unquote(name),
                                   unquote(opts)
                                 )
    end
  end
end
