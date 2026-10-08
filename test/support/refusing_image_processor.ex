defmodule PhxMediaLibrary.RefusingImageProcessor do
  @moduledoc """
  Image processor for tests: every `open/1` returns `{:error, :refused}`,
  as an unreadable image would, so tests can check how jobs fail.
  """

  @behaviour PhxMediaLibrary.ImageProcessor

  @impl true
  def open(_path), do: {:error, :refused}

  @impl true
  def apply_conversion(_image, _conversion), do: {:error, :refused}

  @impl true
  def save(_image, _path, _opts \\ []), do: {:error, :refused}

  @impl true
  def dimensions(_image), do: {:error, :refused}

  @impl true
  def tiny_placeholder(_image), do: {:error, :refused}
end
