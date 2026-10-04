defmodule PhxMediaLibrary.AbsoluteUrlTest do
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.{FakeEndpoint, Media}

  defp media(disk) do
    %Media{
      uuid: "8f2c4d1e-0000-4000-8000-000000000000",
      collection_name: "images",
      file_name: "red-dress.jpg",
      mime_type: "image/jpeg",
      disk: disk,
      mediable_type: "products",
      mediable_id: "42",
      checksum: "a1b2c3d4e5f6",
      custom_properties: %{},
      generated_conversions: %{},
      responsive_images: %{}
    }
  end

  test "joins a relative URL with the endpoint's URL" do
    url = PhxMediaLibrary.absolute_url(media("memory"), nil, FakeEndpoint)
    assert url == "https://shop.example" <> PhxMediaLibrary.url(media("memory"))
  end

  test "accepts a URL string, e.g. a CDN host" do
    assert PhxMediaLibrary.absolute_url(media("memory"), nil, "https://cdn.example") =~
             ~r{^https://cdn\.example/test-uploads/products/42/}
  end

  test "passes options through" do
    assert PhxMediaLibrary.absolute_url(media("memory"), nil, FakeEndpoint, cache_bust: true) =~
             ~r/\?vsn=a1b2c3d4$/
  end

  test "leaves URLs that are already absolute alone" do
    disks = Application.get_env(:phx_media_library, :disks)
    on_exit(fn -> Application.put_env(:phx_media_library, :disks, disks) end)

    Application.put_env(
      :phx_media_library,
      :disks,
      Keyword.put(disks, :cdn,
        adapter: PhxMediaLibrary.Storage.Memory,
        base_url: "https://media.example/files"
      )
    )

    assert PhxMediaLibrary.absolute_url(media("cdn"), nil, FakeEndpoint) =~
             ~r{^https://media\.example/files/}
  end
end
