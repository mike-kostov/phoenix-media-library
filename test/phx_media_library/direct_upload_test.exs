defmodule PhxMediaLibrary.DirectUploadTest do
  @moduledoc "complete_external_upload/4 trusts the stored object, not the client."

  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Config, StorageWrapper}
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>

  setup do
    post = Repo.insert!(%PhxMediaLibrary.TestPost{id: Ecto.UUID.generate(), title: "Post"})
    %{post: post, storage: Config.storage_adapter(:memory)}
  end

  defp put!(storage, path, content) do
    :ok = StorageWrapper.put(storage, path, content)
    path
  end

  defp complete(post, collection, path, opts) do
    PhxMediaLibrary.complete_external_upload(post, collection, path, [disk: :memory] ++ opts)
  end

  test "a missing object is an error", %{post: post} do
    path = "posts/#{post.id}/#{Ecto.UUID.generate()}/ghost.txt"
    assert {:error, :not_found} = complete(post, :images, path, filename: "ghost.txt")
  end

  test "size and type come from the stored object, not the client", %{
    post: post,
    storage: storage
  } do
    path = put!(storage, "posts/#{post.id}/#{Ecto.UUID.generate()}/logo.png", @png)

    assert {:ok, media} =
             complete(post, :images, path,
               filename: "logo.png",
               content_type: "text/html",
               size: 1
             )

    assert media.size == byte_size(@png)
    assert media.mime_type == "image/png"
  end

  test "an object over the collection's max_size is rejected and deleted",
       %{post: post, storage: storage} do
    # :small_files: max_size 1_000, accepts text/plain
    path =
      put!(
        storage,
        "posts/#{post.id}/#{Ecto.UUID.generate()}/big.txt",
        String.duplicate("a", 1_500)
      )

    assert {:error, {:file_too_large, 1_500, 1_000}} =
             complete(post, :small_files, path, filename: "big.txt", size: 10)

    refute StorageWrapper.exists?(storage, path)
  end

  test "an object of a type the collection refuses is rejected and deleted",
       %{post: post, storage: storage} do
    path = put!(storage, "posts/#{post.id}/#{Ecto.UUID.generate()}/notes.txt", @png)

    # The collection's accepts list is checked first, as for regular uploads.
    assert {:error, {:invalid_mime_type, "image/png", ["text/plain"]}} =
             complete(post, :small_files, path, filename: "notes.txt", content_type: "text/plain")

    refute StorageWrapper.exists?(storage, path)
  end

  test "only :filename is required", %{post: post, storage: storage} do
    path = put!(storage, "posts/#{post.id}/#{Ecto.UUID.generate()}/a.txt", "hello")
    assert {:ok, media} = complete(post, :images, path, filename: "a.txt")
    assert media.size == 5
  end

  test "reads the UUID under every path generator's layout", %{post: post, storage: storage} do
    for layout <- [
          fn uuid -> "posts/#{post.id}/#{uuid}/a.txt" end,
          fn uuid -> "#{uuid}/a.txt" end,
          fn uuid -> "2026/10/04/posts/#{post.id}/#{uuid}/a.txt" end,
          fn uuid -> "tenant-7/posts/#{post.id}/#{uuid}/a.txt" end
        ] do
      uuid = Ecto.UUID.generate()
      path = put!(storage, layout.(uuid), "hello")

      assert {:ok, media} = complete(post, :images, path, filename: "a.txt")
      assert media.uuid == uuid, path
    end
  end
end
