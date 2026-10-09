defmodule PhxMediaLibrary.PathGeneratorsTest do
  # The alternative path generators, end to end: store, read, delete.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{AsyncProcessor, Media, PathGenerator}
  alias PhxMediaLibrary.PathGenerator.{DateBased, Flat, Tenant}

  @moduletag :db

  setup do
    for key <- [:path_generator, :async_processor] do
      previous = Application.fetch_env(:phx_media_library, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end)
    end

    Application.put_env(:phx_media_library, :async_processor, AsyncProcessor.Inline)
    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  defp upload(png) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(:images, disk: :local)

    TestRepo.reload!(media)
  end

  defp stored?(media),
    do: Enum.all?(Media.owned_paths(media), &File.exists?(Path.join("priv/static/uploads", &1)))

  for generator <- [Flat, DateBased, Tenant] do
    test "#{inspect(generator)}: an upload's files are where its paths say, and delete removes them",
         %{png: png} do
      Application.put_env(:phx_media_library, :path_generator, unquote(generator))
      media = upload(png)

      assert media.generated_conversions["thumb"]
      assert stored?(media)

      paths = Media.owned_paths(media)
      :ok = PhxMediaLibrary.delete(media)
      refute Enum.any?(paths, &File.exists?(Path.join("priv/static/uploads", &1)))
    end
  end

  test "Flat paths are the uuid and the file name" do
    media = %Media{uuid: "u-1", file_name: "photo.jpg", mediable_type: "posts", mediable_id: "1"}
    assert Flat.relative_path(media, nil) == "u-1/photo.jpg"
    assert Flat.relative_path(media, :thumb) == "u-1/photo_thumb.jpg"
  end

  # Spec 02, B10: the path used the day it was asked for, not the upload's.
  test "DateBased paths keep the day the media was stored", %{png: png} do
    stored = %Media{
      uuid: "u-1",
      file_name: "photo.jpg",
      mediable_type: "posts",
      mediable_id: "1",
      inserted_at: ~U[2020-01-02 23:59:59Z]
    }

    assert DateBased.relative_path(stored, nil) == "2020/01/02/posts/1/u-1/photo.jpg"
    assert DateBased.relative_path(stored, :thumb) == "2020/01/02/posts/1/u-1/photo_thumb.jpg"
    assert DateBased.relative_path(stored, nil, %{date: ~D[2021-05-06]}) =~ "2021/05/06/"

    # An upload stores its file under the day it records.
    Application.put_env(:phx_media_library, :path_generator, DateBased)
    media = upload(png)
    day = media.inserted_at |> DateTime.to_date() |> Calendar.strftime("%Y/%m/%d")
    assert PathGenerator.relative_path(media, nil) =~ ~r{^#{day}/posts/}
    assert stored?(media)
  end

  test "Tenant paths start with the tenant from the context, else \"shared\"" do
    media = %Media{uuid: "u-1", file_name: "photo.jpg", mediable_type: "posts", mediable_id: 7}
    assert Tenant.relative_path(media, nil, %{tenant_id: "acme"}) == "acme/posts/7/u-1/photo.jpg"

    assert Tenant.relative_path(media, :thumb, %{"tenant_id" => 42}) ==
             "42/posts/7/u-1/photo_thumb.jpg"

    assert Tenant.relative_path(media, nil) == "shared/posts/7/u-1/photo.jpg"

    # Through PathGenerator, as the library calls it.
    Application.put_env(:phx_media_library, :path_generator, Tenant)

    assert PathGenerator.relative_path(media, nil, %{tenant_id: "acme"}) ==
             "acme/posts/7/u-1/photo.jpg"
  end
end
