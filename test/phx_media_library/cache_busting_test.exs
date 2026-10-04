defmodule PhxMediaLibrary.CacheBustingTest do
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.{Media, UrlGenerator}

  defp media(attrs \\ %{}) do
    struct(
      %Media{
        uuid: "8f2c4d1e-0000-4000-8000-000000000000",
        collection_name: "images",
        file_name: "dress.jpg",
        mime_type: "image/jpeg",
        disk: "memory",
        mediable_type: "posts",
        mediable_id: "42",
        checksum: "a1b2c3d4e5f6a7b8",
        custom_properties: %{},
        generated_conversions: %{},
        responsive_images: %{}
      },
      attrs
    )
  end

  test "cache_bust adds a vsn fingerprint, which Plug.Static caches for a year" do
    assert UrlGenerator.url(media(), nil, cache_bust: true) =~ ~r/\?vsn=a1b2c3d4$/
    assert PhxMediaLibrary.cdn_url(media()) =~ ~r/\?vsn=a1b2c3d4$/
  end

  test "a signed URL keeps a valid query string" do
    Application.put_env(:phx_media_library, :secret_key_base, String.duplicate("s", 64))
    Application.put_env(:phx_media_library, :download_base_url, "/media")

    on_exit(fn ->
      Application.delete_env(:phx_media_library, :secret_key_base)
      Application.delete_env(:phx_media_library, :download_base_url)
    end)

    url = UrlGenerator.url(media(disk: "local"), nil, signed: true, cache_bust: true)

    assert url =~ ~r/\?sign=.*&vsn=a1b2c3d4$/ or url =~ ~r/\?exp=.*&vsn=a1b2c3d4$/
    assert length(String.split(url, "?")) == 2
  end

  test "no fingerprint without a checksum" do
    refute UrlGenerator.url(media(checksum: nil), nil, cache_bust: true) =~ "vsn"
  end

  test "Plug.Static serves vsn URLs with a long Cache-Control" do
    dir = Path.join(System.tmp_dir!(), "phx_media_static_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "dress.jpg"), "jpeg")
    on_exit(fn -> File.rm_rf(dir) end)

    opts = Plug.Static.init(at: "/uploads", from: dir)

    conn =
      :get
      |> Plug.Test.conn("/uploads/dress.jpg?vsn=a1b2c3d4")
      |> Plug.Static.call(opts)

    assert ["public, max-age=31536000" <> _] = Plug.Conn.get_resp_header(conn, "cache-control")
  end
end
