defmodule PhxMediaLibrary.DownloaderTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Downloader

  doctest Downloader

  # A public IP literal: no DNS lookup, passes the private-network check.
  # Requests never leave the process — Req's `plug:` option answers them.
  @public "http://93.184.215.14"

  defp via(plug, opts \\ []), do: Keyword.put(opts, :req_options, plug: plug)

  defp respond(status, body, headers \\ []) do
    fn conn ->
      headers
      |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
      |> Plug.Conn.send_resp(status, body)
    end
  end

  describe "download/2" do
    test "streams the body to a temp file" do
      assert {:ok, info} =
               Downloader.download(@public <> "/photos/cat.jpg", via(respond(200, "jpegdata")))

      assert File.read!(info.path) == "jpegdata"
      assert info.filename == "cat.jpg"
      assert info.size == 8
      assert info.temp
      File.rm!(info.path)
    end

    test "sanitizes the Content-Disposition filename" do
      plug =
        respond(200, "x", [{"content-disposition", ~s(attachment; filename="../../evil.sh")}])

      assert {:ok, info} = Downloader.download(@public <> "/download", via(plug))
      assert info.filename == "evil.sh"
      File.rm!(info.path)
    end

    test "does not decompress the body" do
      gzipped = :zlib.gzip(String.duplicate("a", 10_000))
      plug = respond(200, gzipped, [{"content-encoding", "gzip"}])

      assert {:ok, info} = Downloader.download(@public <> "/a.bin", via(plug))
      assert File.read!(info.path) == gzipped
      File.rm!(info.path)
    end

    test "stops at max_size" do
      assert {:error, {:file_too_large, _, 10}} =
               Downloader.download(
                 @public <> "/big",
                 via(respond(200, "0123456789ABC"), max_size: 10)
               )
    end

    test "returns the status of a failed response" do
      assert {:error, {:download_failed, 404}} =
               Downloader.download(@public <> "/missing", via(respond(404, "nope")))
    end

    test "refuses private and loopback addresses" do
      for url <- [
            "http://127.0.0.1/x",
            "http://10.0.0.5/x",
            "http://192.168.1.1/x",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/x",
            "http://[::ffff:127.0.0.1]/x"
          ] do
        assert {:error, {:invalid_url, :private_address, _}} =
                 Downloader.download(url, via(respond(200, "secret"))),
               url
      end
    end

    test "allow_private_hosts: true permits private addresses" do
      assert {:ok, info} =
               Downloader.download(
                 "http://10.0.0.5/a.txt",
                 via(respond(200, "intranet"), allow_private_hosts: true)
               )

      assert File.read!(info.path) == "intranet"
      File.rm!(info.path)
    end

    test "follows redirects to public addresses" do
      plug = fn
        %{request_path: "/old"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "/new.png")
          |> Plug.Conn.send_resp(302, "")

        conn ->
          Plug.Conn.send_resp(conn, 200, "png")
      end

      assert {:ok, info} = Downloader.download(@public <> "/old", via(plug))
      assert File.read!(info.path) == "png"
      assert info.filename == "new.png"
      assert info.source_url == @public <> "/old"
      File.rm!(info.path)
    end

    test "re-checks every redirect hop" do
      plug = respond(302, "", [{"location", "http://169.254.169.254/latest/meta-data"}])

      assert {:error, {:invalid_url, :private_address, "169.254.169.254"}} =
               Downloader.download(@public <> "/innocent.jpg", via(plug))
    end

    test "gives up after max_redirects" do
      plug = respond(302, "", [{"location", "/again"}])

      assert {:error, {:download_failed, :too_many_redirects}} =
               Downloader.download(@public <> "/loop", via(plug, max_redirects: 2))
    end
  end
end
