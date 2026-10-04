defmodule PhxMediaLibrary.UrlEncodingTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias PhxMediaLibrary.{Media, PathGenerator, UrlGenerator}
  alias PhxMediaLibrary.Plug.MediaDownload
  alias PhxMediaLibrary.Storage.S3

  doctest PhxMediaLibrary.Storage

  # The :local disk root from test_helper.
  @root "priv/static/uploads"
  @secret String.duplicate("s", 64)

  # Stored before 0.9 under the uploaded name (ADR-015 changed that).
  defp media(file_name) do
    %Media{
      uuid: Ecto.UUID.generate(),
      collection_name: "documents",
      file_name: file_name,
      mime_type: "application/pdf",
      disk: "local",
      mediable_type: "posts",
      mediable_id: "42",
      custom_properties: %{},
      generated_conversions: %{},
      responsive_images: %{}
    }
  end

  defp store(media, content) do
    full_path = Path.join(@root, PathGenerator.relative_path(media, nil))
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    on_exit(fn -> File.rm_rf(Path.dirname(full_path)) end)
  end

  describe "disk URLs" do
    test "percent-encode each path segment" do
      media = media("Report #3.pdf")

      assert UrlGenerator.url(media) ==
               "/uploads/posts/42/#{media.uuid}/Report%20%233.pdf"
    end

    test "Plug.Static serves the file at its URL" do
      for name <- ["Report #3.pdf", "Лятна рокля?.pdf", "a+b&c%20.pdf"] do
        media = media(name)
        store(media, "pdf content")

        opts = Plug.Static.init(at: "/uploads", from: @root)
        conn = :get |> conn(UrlGenerator.url(media)) |> Plug.Static.call(opts)

        assert conn.status == 200, "#{name} was not served"
        assert conn.resp_body == "pdf content"
      end
    end

    test "a signed download URL verifies in MediaDownload" do
      media = media("Report #3.pdf")
      store(media, "pdf content")

      previous = Application.fetch_env(:phx_media_library, :secret_key_base)
      Application.put_env(:phx_media_library, :secret_key_base, @secret)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, :secret_key_base, value)
          :error -> Application.delete_env(:phx_media_library, :secret_key_base)
        end
      end)

      url = UrlGenerator.download_url(media, nil, signed: true, download_base_url: "/media")

      assert url =~ "/media/posts/42/#{media.uuid}/Report%20%233.pdf?"

      opts = MediaDownload.init(disk: :local, require_signed: true)
      conn = :get |> conn(String.replace_prefix(url, "/media", "")) |> download(opts)

      assert conn.status == 200
      assert conn.resp_body == "pdf content"
    end

    test "an unsigned download URL is served by MediaDownload" do
      media = media("Report #3.pdf")
      store(media, "pdf content")

      url = UrlGenerator.download_url(media, nil, download_base_url: "/media")
      assert url =~ "/media/posts/42/#{media.uuid}/Report%20%233.pdf?"

      opts = MediaDownload.init(disk: :local)
      conn = :get |> conn(String.replace_prefix(url, "/media", "")) |> download(opts)

      assert conn.status == 200
    end
  end

  test "MediaDownload refuses an encoded path outside the root" do
    opts = MediaDownload.init(disk: :local)

    for path <- ["/..%2F..%2Fmix.exs", "/%2E%2E/%2E%2E/mix.exs"] do
      assert (:get |> conn(path) |> download(opts)).status == 403
    end
  end

  describe "S3 public URLs" do
    test "percent-encode each path segment" do
      assert S3.url("posts/1/u/Report #3.pdf", bucket: "media", region: "eu-west-1") ==
               "https://media.s3.eu-west-1.amazonaws.com/posts/1/u/Report%20%233.pdf"

      assert S3.url("posts/1/u/Report #3.pdf",
               bucket: "media",
               base_url: "https://cdn.example.com"
             ) == "https://cdn.example.com/posts/1/u/Report%20%233.pdf"
    end
  end

  describe "S3 against the container" do
    @describetag :s3

    test "public and signed URLs both reach the object" do
      s3 = PhxMediaLibrary.Ministack.disk_opts()
      path = "tests/#{Ecto.UUID.generate()}/Report #3.pdf"
      :ok = S3.put(path, "pdf content", s3)

      for url <- [S3.url(path, s3), S3.url(path, Keyword.put(s3, :signed, true))] do
        assert %{status: 200, body: "pdf content"} = Req.get!(url, retry: false)
      end
    end
  end

  defp download(conn, opts) do
    conn |> Plug.Conn.fetch_query_params() |> MediaDownload.call(opts)
  end
end
