defmodule PhxMediaLibrary.PreloadingTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, TestPost}
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  defp post_with_images(count) do
    post = Repo.insert!(%TestPost{id: Ecto.UUID.generate(), title: "Dress"})

    for n <- 1..count do
      create_media(
        mediable_id: post.id,
        mediable_type: "posts",
        collection_name: "images",
        file_name: "dress-#{n}.jpg",
        order_column: count - n + 1
      )
    end

    post
  end

  test "helpers use preloaded media instead of querying" do
    post = post_with_images(2) |> Repo.preload(:images)

    # Delete the rows: anything still answering must come from the preload.
    Repo.delete_all(Media)

    assert [%Media{file_name: "dress-2.jpg"}, %Media{file_name: "dress-1.jpg"}] =
             PhxMediaLibrary.get_media(post, :images)

    assert PhxMediaLibrary.get_first_media_url(post, :images) =~ "dress-2.jpg"
  end

  test "the general :media association serves any collection" do
    post = post_with_images(1) |> Repo.preload(:media)
    Repo.delete_all(Media)

    assert [%Media{collection_name: "images"}] = PhxMediaLibrary.get_media(post, :images)
    assert PhxMediaLibrary.get_media(post, :gallery) == []
  end

  test "without a preload it queries, as before" do
    post = post_with_images(1)
    assert [%Media{}] = PhxMediaLibrary.get_media(post, :images)
  end

  test "preloaded trashed media stays hidden" do
    Application.put_env(:phx_media_library, :soft_deletes, true)
    on_exit(fn -> Application.delete_env(:phx_media_library, :soft_deletes) end)

    post = post_with_images(2)
    [first | _] = PhxMediaLibrary.get_media(post, :images)
    {:ok, _} = Media.soft_delete(first)

    post = Repo.preload(post, :images)
    assert [%Media{file_name: "dress-1.jpg"}] = PhxMediaLibrary.get_media(post, :images)
  end
end
