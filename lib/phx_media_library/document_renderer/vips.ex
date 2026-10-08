if Code.ensure_loaded?(Image) do
  defmodule PhxMediaLibrary.DocumentRenderer.Vips do
    @moduledoc """
    Renders a PDF's first page with libvips, when it was built with PDF
    support (pdfium or poppler). The precompiled libvips that `:image`
    ships can't read PDFs; a system libvips (`VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`)
    often can.
    """

    @behaviour PhxMediaLibrary.DocumentRenderer

    alias Vix.Vips.Foreign

    @doc "Whether libvips can load PDFs."
    @impl true
    def available?, do: match?({:ok, _loader}, Foreign.find_load("probe.pdf"))

    @doc """
    Render the first page of `source` to the PNG `destination`.

    ## Examples

        :ok = PhxMediaLibrary.DocumentRenderer.Vips.render_first_page("a.pdf", "/tmp/a.png", size: 2048)

    """
    @impl true
    def render_first_page(source, destination, opts) do
      with {:ok, page} <- Image.thumbnail(source, Keyword.get(opts, :size, 2048)),
           {:ok, _image} <- Image.write(page, destination) do
        :ok
      end
    end
  end
end
