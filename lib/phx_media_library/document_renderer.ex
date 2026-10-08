defmodule PhxMediaLibrary.DocumentRenderer do
  @moduledoc """
  Behaviour for rendering a document's first page as an image, so PDFs get
  conversions (`:thumb`, `:preview`) and a placeholder like images do. The
  PDF itself stays the file that is downloaded.

  ## Built-in adapters

    * `PhxMediaLibrary.DocumentRenderer.Vips`: libvips, when it was built
      with PDF support (the precompiled libvips of `:image` isn't)
    * `PhxMediaLibrary.DocumentRenderer.Pdftoppm`: the `pdftoppm` tool of
      poppler (`brew install poppler`, `apt-get install poppler-utils`)
    * `PhxMediaLibrary.DocumentRenderer.Null`: no rendering; PDFs are
      stored without conversions, and a warning is logged once

  The first available one is used, like the video processor; set
  `config :phx_media_library, document_renderer: MyApp.Renderer` to choose.

  ## A custom adapter

      defmodule MyApp.Renderer do
        @behaviour PhxMediaLibrary.DocumentRenderer

        @impl true
        def available?, do: true

        @impl true
        def render_first_page(pdf_path, png_path, opts) do
          # write the first page to png_path, at most opts[:size] pixels on its longest side
          :ok
        end
      end
  """

  require Logger

  alias PhxMediaLibrary.Config

  @logged_key {__MODULE__, :unavailable_logged}

  @doc "Whether the adapter can render on this system."
  @callback available?() :: boolean()

  @doc """
  Render the first page of the PDF at `source` as a PNG at `destination`,
  at most `opts[:size]` pixels on its longest side.
  """
  @callback render_first_page(source :: Path.t(), destination :: Path.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Whether files of `mime_type` give an image to convert: images, and PDFs
  when a renderer is available.

  ## Examples

      iex> PhxMediaLibrary.DocumentRenderer.image_source?("image/png")
      true

      iex> PhxMediaLibrary.DocumentRenderer.image_source?("text/plain")
      false

  """
  @spec image_source?(String.t() | nil) :: boolean()
  def image_source?("image/" <> _), do: true
  def image_source?(mime_type), do: renderable?(mime_type)

  @doc """
  Whether files of `mime_type` are documents the configured renderer can
  render. Logs once when a PDF arrives and no renderer is available.

  ## Examples

      PhxMediaLibrary.DocumentRenderer.renderable?("application/pdf")
      #=> true

  """
  @spec renderable?(String.t() | nil) :: boolean()
  def renderable?("application/pdf") do
    Config.document_renderer().available?() or log_unavailable_once()
  end

  def renderable?(_mime_type), do: false

  defp log_unavailable_once do
    unless :persistent_term.get(@logged_key, false) do
      :persistent_term.put(@logged_key, true)

      Logger.warning(
        "[PhxMediaLibrary] PDFs are stored without thumbnails: no document renderer is " <>
          "available (install poppler for pdftoppm, or a libvips built with PDF support)"
      )
    end

    false
  end
end
