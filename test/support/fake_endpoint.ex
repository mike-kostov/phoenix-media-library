defmodule PhxMediaLibrary.FakeEndpoint do
  @moduledoc "Stands in for a Phoenix endpoint in tests: only `url/0`."

  @doc "The endpoint's base URL."
  def url, do: "https://shop.example"
end
