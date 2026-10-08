defmodule PhxMediaLibrary.TransferTest do
  # Spec 02, F4: copy and move media to another record or collection.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{AsyncProcessor, Media, PathGenerator, StorageWrapper}

  @moduletag :db

  setup do
    previous = Application.fetch_env(:phx_media_library, :async_processor)
    Application.put_env(:phx_media_library, :async_processor, AsyncProcessor.Inline)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :async_processor, value)
        :error -> Application.delete_env(:phx_media_library, :async_processor)
      end
    end)

    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  defp add(source, collection, opts \\ []) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(source)
      |> PhxMediaLibrary.with_custom_properties(%{"alt" => "A red dress"})
      |> PhxMediaLibrary.to_collection(collection, Keyword.put_new(opts, :disk, :local))

    cleanup(media)
  end

  defp cleanup(media) do
    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    TestRepo.reload!(media)
  end

  defp stored?(media) do
    storage = PhxMediaLibrary.Config.storage_adapter(media.disk)
    Enum.all?(Media.owned_paths(media), &StorageWrapper.exists?(storage, &1))
  end

  defp none_stored?(media, paths) do
    storage = PhxMediaLibrary.Config.storage_adapter(media.disk)
    not Enum.any?(paths, &StorageWrapper.exists?(storage, &1))
  end

  describe "copy_media/4" do
    test "a new record with its own files; the original's deletion leaves it whole", %{png: png} do
      media = add(png, :images)
      target = create_test_post()

      assert {:ok, copy} = PhxMediaLibrary.copy_media(media, target, :gallery, disk: :local)
      copy = cleanup(copy)

      assert copy.id != media.id
      assert {copy.mediable_id, copy.collection_name} == {target.id, "gallery"}
      assert copy.checksum == media.checksum
      assert copy.custom_properties["alt"] == "A red dress"
      assert Media.original_file_name(copy) == Media.original_file_name(media)
      assert copy.generated_conversions["thumb"]
      assert Media.owned_paths(copy) -- Media.owned_paths(media) == Media.owned_paths(copy)

      :ok = PhxMediaLibrary.delete(media)
      assert stored?(copy)
    end

    test "the target's rules refuse it, and nothing is created", %{png: png} do
      media = add(png, :images)
      count = TestRepo.aggregate(Media, :count)

      assert {:error, {:invalid_mime_type, "image/png", _}} =
               PhxMediaLibrary.copy_media(media, create_test_post(), :documents)

      assert TestRepo.aggregate(Media, :count) == count
    end

    test "the target collection's derivatives are made", %{png: png} do
      media = add(png, :images)

      assert {:ok, copy} =
               PhxMediaLibrary.copy_media(media, create_test_post(), :avif_responsive,
                 disk: :local
               )

      copy = cleanup(copy)

      assert is_binary(copy.custom_properties["avif"])
      assert copy.generated_conversions["thumb"] == ["avif", "webp"]
      refute Map.has_key?(media.custom_properties, "avif")
    end

    test "works when the collection dropped the original", %{png: png} do
      media = add(png, :webp_only)

      refute StorageWrapper.exists?(
               PhxMediaLibrary.Config.storage_adapter(:local),
               PathGenerator.relative_path(media, nil)
             )

      assert {:ok, copy} =
               PhxMediaLibrary.copy_media(media, create_test_post(), :images, disk: :local)

      copy = cleanup(copy)
      assert copy.mime_type == "image/webp"
      assert stored?(copy)
    end
  end

  describe "move_media/4" do
    test "keeps the record; files follow, the old ones are gone", %{png: png} do
      media = add(png, :images)
      old_paths = Media.owned_paths(media)
      old_url = PhxMediaLibrary.url(media)
      target = create_test_post()

      assert {:ok, moved} = PhxMediaLibrary.move_media(media, target, :gallery, disk: :local)
      moved = cleanup(moved)

      assert moved.id == media.id
      assert moved.uuid != media.uuid
      assert {moved.mediable_id, moved.collection_name} == {target.id, "gallery"}
      assert moved.custom_properties["alt"] == "A red dress"
      assert PhxMediaLibrary.url(moved) != old_url
      assert stored?(moved)
      assert none_stored?(media, old_paths)
      assert TestRepo.aggregate(Media, :count) == 1
    end

    test "a move the target's rules refuse changes nothing", %{png: png} do
      small = create_temp_image(format: :png, width: 50, height: 50)
      on_exit(fn -> File.rm(small) end)
      media = add(small, :images)

      assert {:error, {:image_too_narrow, 50, 100}} =
               PhxMediaLibrary.move_media(media, create_test_post(), :sized)

      assert TestRepo.reload!(media) == media
      assert stored?(media)
      _ = png
    end

    test "the target's limits apply: single_file keeps the moved one", %{png: png} do
      target = create_test_post()

      {:ok, existing} =
        target |> PhxMediaLibrary.add(png) |> PhxMediaLibrary.to_collection(:avatar, disk: :local)

      cleanup(existing)
      media = add(png, :images)

      assert {:ok, moved} = PhxMediaLibrary.move_media(media, target, :avatar, disk: :local)
      cleanup(moved)

      assert [only] = PhxMediaLibrary.get_media(target, :avatar)
      assert only.id == media.id
      refute TestRepo.get(Media, existing.id)
    end

    test "derivatives are made again for the target collection", %{png: png} do
      media = add(png, :avif_responsive)
      assert is_binary(media.custom_properties["avif"])

      assert {:ok, moved} =
               PhxMediaLibrary.move_media(media, create_test_post(), :images, disk: :local)

      moved = cleanup(moved)

      refute Map.has_key?(moved.custom_properties, "avif")
      assert moved.generated_conversions["thumb"] == "webp"
      assert PhxMediaLibrary.ResponsiveImages.variants(moved, nil) == []
      assert stored?(moved)
    end
  end

  describe "on S3" do
    @describetag :s3

    setup do
      disks = Application.get_env(:phx_media_library, :disks)
      on_exit(fn -> Application.put_env(:phx_media_library, :disks, disks) end)
      s3 = [adapter: PhxMediaLibrary.Storage.S3] ++ PhxMediaLibrary.Ministack.disk_opts()
      Application.put_env(:phx_media_library, :disks, Keyword.put(disks, :s3, s3))
      :ok
    end

    test "copy and move from local disk to S3 and back", %{png: png} do
      media = add(png, :images)
      old_paths = Media.owned_paths(media)

      assert {:ok, moved} =
               PhxMediaLibrary.move_media(media, create_test_post(), :gallery, disk: :s3)

      moved = cleanup(moved)
      assert moved.disk == "s3"
      assert stored?(moved)
      assert none_stored?(media, old_paths)

      assert {:ok, copy} =
               PhxMediaLibrary.copy_media(moved, create_test_post(), :images, disk: :local)

      copy = cleanup(copy)
      assert copy.checksum == media.checksum
      assert stored?(copy)
    end
  end
end
