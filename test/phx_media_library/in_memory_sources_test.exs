defmodule PhxMediaLibrary.InMemorySourcesTest do
  # Spec 02, F3: media from a binary, base64 or a stream, checked like any
  # upload.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.Media

  @moduletag :db

  setup do
    png = create_temp_image(format: :png, width: 40, height: 30)
    on_exit(fn -> File.rm(png) end)
    %{png: png, post: create_test_post()}
  end

  defp add(post, source, collection \\ :images) do
    result = post |> PhxMediaLibrary.add(source) |> PhxMediaLibrary.to_collection(collection)
    with {:ok, media} <- result, do: on_exit(fn -> Media.delete_files(media) end)
    result
  end

  defp same_as_path(media, from_path) do
    assert media.checksum == from_path.checksum
    assert media.size == from_path.size
    assert media.mime_type == "image/png"
    assert media.metadata["width"] == 40
  end

  test "binary, base64, a data URI and a stream store what the path does", %{png: png, post: post} do
    {:ok, from_path} = add(post, png)
    bytes = File.read!(png)

    sources = [
      {:binary, bytes, "chart.png"},
      {:base64, Base.encode64(bytes), "chart.png"},
      {:base64, "data:image/png;base64," <> Base.encode64(bytes), "chart.png"},
      {:stream, File.stream!(png, 100), "chart.png"}
    ]

    for source <- sources do
      assert {:ok, media} = add(post, source)
      same_as_path(media, from_path)
      assert media.metadata["original_file_name"] == "chart.png"
    end
  end

  test "using_filename/2 wins over the tuple's filename", %{png: png, post: post} do
    {:ok, media} =
      post
      |> PhxMediaLibrary.add({:binary, File.read!(png), "chart.png"})
      |> PhxMediaLibrary.using_filename("sales.png")
      |> PhxMediaLibrary.to_collection(:images)

    on_exit(fn -> Media.delete_files(media) end)
    assert media.metadata["original_file_name"] == "sales.png"
  end

  test "content that doesn't match its name is refused", %{post: post} do
    assert {:error, {:content_type_mismatch, _detected, "image/png"}} =
             add(post, {:binary, "MZ" <> String.duplicate("x", 100), "chart.png"})
  end

  test "size and pixel limits apply", %{png: png, post: post} do
    big = String.duplicate("a", 2_000)

    assert {:error, {:file_too_large, 2_000, 1_000}} =
             add(post, {:binary, big, "notes.txt"}, :small_files)

    # A stream stops at max_size instead of reading on.
    endless = Stream.repeatedly(fn -> String.duplicate("a", 600) end)

    assert {:error, {:file_too_large, 1_200, 1_000}} =
             add(post, {:stream, endless, "notes.txt"}, :small_files)

    assert {:error, {:image_too_large, 1_200, 100}} =
             add(post, {:binary, File.read!(png), "chart.png"}, :tiny_images)
  end

  test "invalid base64 is an error", %{post: post} do
    assert {:error, :invalid_base64} = add(post, {:base64, "not base64!", "chart.png"})
  end

  test "temporary files are removed", %{png: png, post: post} do
    temp_files = fn -> Path.wildcard(Path.join(System.tmp_dir!(), "phx_media_source_*")) end
    before = temp_files.()

    {:ok, _} = add(post, {:binary, File.read!(png), "chart.png"})
    {:error, _} = add(post, {:binary, String.duplicate("a", 2_000), "notes.txt"}, :small_files)

    assert_raise RuntimeError, fn ->
      add(post, {:stream, Stream.map([1, 2], fn _ -> raise "boom" end), "notes.txt"})
    end

    assert temp_files.() -- before == []
  end
end
