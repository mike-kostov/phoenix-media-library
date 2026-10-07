defmodule PhxMediaLibrary.FileNamingTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhxMediaLibrary.{Media, PathGenerator}

  @moduletag :db

  setup do
    previous = Application.fetch_env(:phx_media_library, :file_naming)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :file_naming, value)
        :error -> Application.delete_env(:phx_media_library, :file_naming)
      end
    end)

    png = create_temp_image(format: :png, width: 20, height: 20)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  defp add(source, collection, filename) do
    post = create_test_post()

    {:ok, media} =
      post
      |> PhxMediaLibrary.add(source)
      |> PhxMediaLibrary.using_filename(filename)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    on_exit(fn -> Media.delete_files(media) end)
    {post, media}
  end

  test ":semantic by default: type, id, collection and uuid", %{png: png} do
    {post, media} = add(png, :images, "Лятна рокля #1.png")

    assert media.file_name == "posts_#{post.id}_images_#{media.uuid}.png"
    assert media.metadata["original_file_name"] == "Лятна рокля #1.png"
    assert File.exists?(PathGenerator.full_path(media, nil))
  end

  test "a collection's :slug overrides the global setting", %{png: png} do
    {_post, media} = add(png, :seo_images, "Red Summer Dress (2).PNG")
    assert media.file_name == "red-summer-dress-2.png"
  end

  test "a collection's :random reveals nothing", %{png: png} do
    {post, media} = add(png, :private_docs, "Salary 2026.png")

    assert media.file_name =~ ~r/^[a-z2-7]{26}\.png$/
    refute media.file_name =~ "salary"
    refute media.file_name =~ to_string(post.id)
  end

  test "the global setting applies to collections without their own", %{png: png} do
    Application.put_env(:phx_media_library, :file_naming, :slug)
    {_post, media} = add(png, :images, "Café Menu.png")
    assert media.file_name == "cafe-menu.png"
  end

  test "the extension follows the content, not the uploader", %{png: png} do
    {_post, media} = add(png, :seo_images, "photo.jpg")
    assert media.file_name == "photo.png"
  end

  test "conversions follow the stored name", %{png: png} do
    {_post, media} = add(png, :seo_images, "Dress.png")
    assert Path.basename(PathGenerator.relative_path(media, :thumb)) =~ ~r/^dress.thumb\.png$/
  end

  test "alt text comes from the uploaded name, never the stored one", %{png: png} do
    {_post, media} = add(png, :images, "red-summer_dress.png")
    assert Media.alt_text(media) == "red summer dress"

    html =
      render_component(&PhxMediaLibrary.ViewHelpers.media_img/1,
        media: media
      )

    assert html =~ ~s(alt="red summer dress")
    refute html =~ ~s(alt="posts_)
  end

  test "explicit alt text wins" do
    assert Media.alt_text(%Media{custom_properties: %{"alt" => "A red dress"}, metadata: %{}}) ==
             "A red dress"
  end

  test "media from before file naming uses its file_name" do
    media = %Media{custom_properties: %{}, metadata: %{}, file_name: "Summer Photo.jpg"}
    assert Media.alt_text(media) == "Summer Photo"
  end

  test "direct uploads store under the name presigned_upload chose" do
    post = create_test_post()
    storage_path = "posts/#{post.id}/#{Ecto.UUID.generate()}/posts_x_images_y.jpg"

    :ok =
      PhxMediaLibrary.StorageWrapper.put(
        PhxMediaLibrary.Config.storage_adapter(:local),
        storage_path,
        "jpeg"
      )

    on_exit(fn ->
      PhxMediaLibrary.StorageWrapper.delete(
        PhxMediaLibrary.Config.storage_adapter(:local),
        storage_path
      )
    end)

    {:ok, media} =
      PhxMediaLibrary.complete_external_upload(post, :images, storage_path,
        filename: "Holiday Photo.jpg",
        disk: :local
      )

    assert media.file_name == "posts_x_images_y.jpg"
    assert media.metadata["original_file_name"] == "Holiday Photo.jpg"
  end
end
