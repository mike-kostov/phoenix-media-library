defmodule PhxMediaLibrary.DocumentRenderer.Null do
  @moduledoc """
  The document renderer used when none is available: PDFs are stored
  without conversions or placeholders.
  """

  @behaviour PhxMediaLibrary.DocumentRenderer

  @doc "Always `false`."
  @impl true
  def available?, do: false

  @doc "Always `{:error, :no_document_renderer}`."
  @impl true
  def render_first_page(_source, _destination, _opts), do: {:error, :no_document_renderer}
end
