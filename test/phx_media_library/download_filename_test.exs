defmodule PhxMediaLibrary.DownloadFilenameTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias PhxMediaLibrary.{FileName, Media, PathGenerator, UrlGenerator}
  alias PhxMediaLibrary.Plug.MediaDownload

  @root "priv/static/uploads"
  @secret String.duplicate("s", 64)

  describe "FileName.content_disposition/1" do
    test "an ASCII fallback and the UTF-8 name" do
      assert FileName.content_disposition("Лятна рокля.pdf") ==
               ~s(attachment; filename="Lyatna roklya.pdf"; ) <>
                 "filename*=UTF-8''%D0%9B%D1%8F%D1%82%D0%BD%D0%B0%20%D1%80%D0%BE%D0%BA%D0%BB%D1%8F.pdf"
    end

    test "quotes and line breaks can't break the header" do
      header = FileName.content_disposition(~s(a"b\r\nSet-Cookie: x.pdf))
      refute header =~ "\r"
      refute header =~ "\n"
      # "\r\n" is one grapheme: it becomes "_".
      assert header =~ ~s(filename="a'b_Set-Cookie: x.pdf")
    end

    test "characters without a transliteration become _" do
      assert FileName.content_disposition("报告.pdf") =~ ~s(filename="__.pdf")
    end
  end

  describe "disk downloads" do
    setup do
      previous = Application.fetch_env(:phx_media_library, :secret_key_base)
      Application.put_env(:phx_media_library, :secret_key_base, @secret)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, :secret_key_base, value)
          :error -> Application.delete_env(:phx_media_library, :secret_key_base)
        end
      end)

      media = %Media{
        uuid: Ecto.UUID.generate(),
        collection_name: "documents",
        file_name: "posts_42_documents_x.pdf",
        mime_type: "application/pdf",
        disk: "local",
        mediable_type: "posts",
        mediable_id: "42",
        metadata: %{"original_file_name" => "Лятна рокля.pdf"},
        custom_properties: %{}
      }

      full_path = Path.join(@root, PathGenerator.relative_path(media, nil))
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, "pdf")
      on_exit(fn -> File.rm_rf(Path.dirname(full_path)) end)
      %{media: media}
    end

    defp get(url) do
      :get
      |> conn(String.replace_prefix(url, "/media", ""))
      |> Plug.Conn.fetch_query_params()
      |> MediaDownload.call(MediaDownload.init(disk: :local))
    end

    defp disposition(conn), do: Plug.Conn.get_resp_header(conn, "content-disposition")

    test "a signed download sends the uploaded name", %{media: media} do
      url = UrlGenerator.download_url(media, nil, signed: true, download_base_url: "/media")
      conn = get(url)

      assert conn.status == 200
      assert [header] = disposition(conn)
      assert header =~ ~s(filename="Lyatna roklya.pdf")
      assert header =~ "filename*=UTF-8''%D0%9B"
    end

    test "changing the name in a signed URL fails verification", %{media: media} do
      url = UrlGenerator.download_url(media, nil, signed: true, download_base_url: "/media")
      tampered = String.replace(url, ~r/name=[^&]+/, "name=evil.exe")

      assert get(tampered).status == 403
    end

    test "an unsigned download URL keeps the stored name", %{media: media} do
      url = UrlGenerator.download_url(media, nil, download_base_url: "/media")
      refute url =~ "name="

      conn = get(url <> "&name=evil.exe")
      assert [header] = disposition(conn)
      assert header =~ ~s(filename="posts_42_documents_x.pdf")
    end
  end

  describe "S3 downloads" do
    test "carry the uploaded name" do
      disks = Application.get_env(:phx_media_library, :disks)
      on_exit(fn -> Application.put_env(:phx_media_library, :disks, disks) end)

      s3 = [
        adapter: PhxMediaLibrary.Storage.S3,
        bucket: "media",
        region: "eu-west-1",
        access_key_id: "key",
        secret_access_key: "secret"
      ]

      Application.put_env(:phx_media_library, :disks, Keyword.put(disks, :s3, s3))

      media = %Media{
        uuid: Ecto.UUID.generate(),
        collection_name: "documents",
        file_name: "stored.pdf",
        disk: "s3",
        mediable_type: "posts",
        mediable_id: "42",
        metadata: %{"original_file_name" => "Лятна рокля.pdf"},
        custom_properties: %{}
      }

      query =
        UrlGenerator.download_url(media)
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query["response-content-disposition"] =~ ~s(filename="Lyatna roklya.pdf")
      assert query["response-content-disposition"] =~ "filename*=UTF-8''%D0%9B"
    end
  end
end
