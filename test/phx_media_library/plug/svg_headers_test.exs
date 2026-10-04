defmodule PhxMediaLibrary.Plug.SvgHeadersTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias PhxMediaLibrary.Plug.MediaDownload

  doctest PhxMediaLibrary.Plug.StaticHeaders

  @csp "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox"

  setup do
    # Under the :local disk root from test_helper, so MediaDownload finds it.
    dir = "svg_headers_#{System.unique_integer([:positive])}"
    root = Path.join("priv/static/uploads", dir)
    File.mkdir_p!(root)
    svg = ~s{<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>}
    File.write!(Path.join(root, "logo.svg"), svg)
    File.write!(Path.join(root, "photo.jpg"), "jpeg")
    on_exit(fn -> File.rm_rf(root) end)
    %{dir: dir, root: root}
  end

  defp header(conn, name), do: Plug.Conn.get_resp_header(conn, name)

  describe "Plug.Static with StaticHeaders" do
    defp static(path, root) do
      opts =
        Plug.Static.init(
          at: "/uploads",
          from: root,
          headers: {PhxMediaLibrary.Plug.StaticHeaders, :headers, []}
        )

      :get |> conn(path) |> Plug.Static.call(opts)
    end

    test "serves SVG with a sandboxing CSP and nosniff", %{root: root} do
      conn = static("/uploads/logo.svg", root)

      assert conn.status == 200
      assert header(conn, "content-security-policy") == [@csp]
      assert header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "leaves other files alone", %{root: root} do
      conn = static("/uploads/photo.jpg", root)

      assert conn.status == 200
      assert header(conn, "content-security-policy") == []
    end
  end

  describe "Plug.MediaDownload" do
    defp download(path) do
      opts = MediaDownload.init(disk: :local)
      :get |> conn("/" <> path) |> MediaDownload.call(opts)
    end

    test "serves SVG with the same headers", %{dir: dir} do
      conn = download("#{dir}/logo.svg")

      assert conn.status == 200
      assert header(conn, "content-security-policy") == [@csp]
      assert header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "sends no CSP for other files", %{dir: dir} do
      conn = download("#{dir}/photo.jpg")

      assert conn.status == 200
      assert header(conn, "content-security-policy") == []
    end
  end
end
