defmodule PhxMediaLibrary.Plug.MediaDownloadTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias PhxMediaLibrary.Plug.MediaDownload

  setup do
    # Under the :local disk root from test_helper, so MediaDownload finds it.
    dir = "media_download_#{System.unique_integer([:positive])}"
    root = Path.join("priv/static/uploads", dir)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "report.pdf"), "pdf content")
    on_exit(fn -> File.rm_rf(root) end)
    %{dir: dir}
  end

  # Plug.Conn.send_file/3 runs before_send callbacks with state :set_file;
  # send_resp/3 with :set.
  defp download(path) do
    test = self()

    :get
    |> conn(path)
    |> Plug.Conn.register_before_send(fn conn ->
      send(test, {:sent_as, conn.state})
      conn
    end)
    |> MediaDownload.call(MediaDownload.init(disk: :local))
  end

  test "serves the file with send_file, not from memory", %{dir: dir} do
    conn = download("/#{dir}/report.pdf?dl=1")

    assert_received {:sent_as, :set_file}
    assert conn.status == 200
    assert conn.resp_body == "pdf content"
  end

  test "keeps its headers", %{dir: dir} do
    conn = download("/#{dir}/report.pdf?dl=1")

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/pdf; charset=utf-8"]

    assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="report.pdf"; filename*=UTF-8''report.pdf)
           ]

    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "a missing file is a 404", %{dir: dir} do
    assert download("/#{dir}/ghost.pdf").status == 404
  end
end
