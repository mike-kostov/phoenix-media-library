defmodule PhxMediaLibrary.DocumentRenderer.Null do
  @moduledoc """
  The document renderer used when none is available: PDFs are stored
  without conversions or placeholders.
  """

  @behaviour PhxMediaLibrary.DocumentRenderer

  @doc "Always `false`."
  @spec available?() :: boolean()
  @impl true
  def available?, do: false

  @doc "Always `{:error, :no_document_renderer}`."
  @spec render_first_page(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  @impl true
  def render_first_page(_source, _destination, _opts), do: {:error, :no_document_renderer}
end
