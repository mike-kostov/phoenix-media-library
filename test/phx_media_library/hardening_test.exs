defmodule PhxMediaLibrary.HardeningTest do
  @moduledoc """
  Regression tests for the 0.8.4 security and correctness fixes: unsafe
  upload filenames, the content-type check, file cleanup on delete, the
  clean task, conversion failures and conversions on remote storage.
  """

  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Config, Conversion, Conversions, Media, PathGenerator, StorageWrapper}
  alias PhxMediaLibrary.Storage.Disk
  alias PhxMediaLibrary.TestRepo, as: Repo

  setup do
    previous = Application.get_env(:phx_media_library, :async_processor)

    Application.put_env(
      :phx_media_library,
      :async_processor,
      PhxMediaLibrary.AsyncProcessor.Inline
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phx_media_library, :async_processor, previous),
        else: Application.delete_env(:phx_media_library, :async_processor)
    end)
  end

  describe "upload filenames" do
    @describetag :db

    test "a path in the client filename can't escape the media directory" do
      path = create_temp_file("hello", "evil.txt")

      upload = %Plug.Upload{
        path: path,
        filename: "../../../../evil.txt",
        content_type: "text/plain"
      }

      assert {:ok, media} =
               create_test_post()
               |> PhxMediaLibrary.add(upload)
               |> PhxMediaLibrary.to_collection(:images, disk: :local)

      assert media.metadata["original_file_name"] == "evil.txt"
      stored = PathGenerator.full_path(media, nil)
      assert File.read!(stored) == "hello"
      assert stored =~ "/#{media.uuid}/#{media.file_name}"

      Media.delete_files(media)
      File.rm(path)
    end
  end

  describe "Disk adapter" do
    setup do
      root = Path.join(System.tmp_dir!(), "phx_media_root_#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root}
    end

    test "refuses paths outside its root", %{root: root} do
      assert {:error, :path_outside_root} = Disk.put("../outside.txt", "x", root: root)
      refute File.exists?(Path.join(Path.dirname(root), "outside.txt"))

      assert {:error, :path_outside_root} = Disk.get("../../etc/passwd", root: root)
      assert {:error, :path_outside_root} = Disk.delete("../x", root: root)
      refute Disk.exists?("../x", root: root)
    end

    test "still works inside its root", %{root: root} do
      assert :ok = Disk.put("a/b/file.txt", "x", root: root)
      assert {:ok, "x"} = Disk.get("a/b/file.txt", root: root)
      assert :ok = Disk.delete("a/b/file.txt", root: root)
    end
  end

  describe "content-type check" do
    @describetag :db

    test "image bytes with an .html name are rejected" do
      png = create_temp_image(format: :png, width: 10, height: 10)

      assert {:error, {:content_type_mismatch, "image/png", "text/html"}} =
               create_test_post()
               |> PhxMediaLibrary.add(png)
               |> PhxMediaLibrary.using_filename("page.html")
               |> PhxMediaLibrary.to_collection(:images, disk: :memory)

      File.rm(png)
    end

    test "a PNG saved as .jpg is accepted and stored as image/png" do
      png = create_temp_image(format: :png, width: 10, height: 10)

      assert {:ok, media} =
               create_test_post()
               |> PhxMediaLibrary.add(png)
               |> PhxMediaLibrary.using_filename("photo.jpg")
               |> PhxMediaLibrary.to_collection(:images, disk: :memory)

      assert media.mime_type == "image/png"
      File.rm(png)
    end
  end

  describe "image size limit" do
    @describetag :db

    setup do
      previous = Application.get_env(:phx_media_library, :max_image_pixels)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phx_media_library, :max_image_pixels, previous),
          else: Application.delete_env(:phx_media_library, :max_image_pixels)
      end)

      png = create_temp_image(format: :png, width: 20, height: 20)
      on_exit(fn -> File.rm(png) end)
      %{png: png}
    end

    defp add_image(png, collection) do
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(collection, disk: :memory)
    end

    test "rejects images over the collection's max_pixels", %{png: png} do
      assert {:error, {:image_too_large, 400, 100}} = add_image(png, :tiny_images)
    end

    test "rejects images over the global max_image_pixels", %{png: png} do
      Application.put_env(:phx_media_library, :max_image_pixels, 399)
      assert {:error, {:image_too_large, 400, 399}} = add_image(png, :images)
    end

    test "the collection setting overrides the global one", %{png: png} do
      Application.put_env(:phx_media_library, :max_image_pixels, 10)
      assert {:ok, _} = add_image(png, :unlimited_images)
    end

    test "images within the default limit are accepted", %{png: png} do
      assert Config.max_image_pixels() == 100_000_000
      assert {:ok, _} = add_image(png, :images)
    end

    test "non-image files are not checked" do
      path = create_temp_file("plain text", "notes.txt")
      assert {:ok, _} = add_image(path, :tiny_images)
      File.rm(path)
    end
  end

  describe "deleting media" do
    @describetag :db

    test "removes the WebP and responsive variants too" do
      post = create_test_post()
      png = create_temp_image(format: :png, width: 400, height: 400)

      {:ok, media} =
        post
        |> PhxMediaLibrary.add(png)
        |> PhxMediaLibrary.to_collection(:responsive_webp, disk: :local)

      owned = Media.owned_paths(media)
      storage = Config.storage_adapter(:local)
      assert %{"webp" => _} = media.custom_properties
      assert length(owned) > 3
      assert Enum.all?(owned, &StorageWrapper.exists?(storage, &1))

      assert {:ok, 1} = PhxMediaLibrary.clear_collection(post, :responsive_webp)

      assert Enum.filter(owned, &StorageWrapper.exists?(storage, &1)) == []
      File.rm(png)
    end
  end

  describe "deleting by an ID from the browser" do
    @describetag :db

    setup do
      mine = create_test_post()
      theirs = create_test_post()

      %{
        mine: mine,
        my_media: create_media(mediable_id: mine.id, collection_name: "images"),
        their_media: create_media(mediable_id: theirs.id, collection_name: "images")
      }
    end

    test "MediaLive only deletes media of its own record", ctx do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, model: ctx.mine, collection: :images}
      }

      {:noreply, socket} =
        PhxMediaLibrary.MediaLive.handle_event(
          "delete_media",
          %{"id" => ctx.their_media.id},
          socket
        )

      assert socket.assigns.flash["error"] == "File not found"
      assert Repo.get(Media, ctx.their_media.id)
    end

    test "MediaLive treats a malformed ID as not found", ctx do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, model: ctx.mine, collection: :images}
      }

      assert {:noreply, _} =
               PhxMediaLibrary.MediaLive.handle_event(
                 "delete_media",
                 %{"id" => "1 OR 1=1"},
                 socket
               )
    end

    test "delete_media_by_id with :model refuses other records' media", ctx do
      assert {:error, :not_found} =
               PhxMediaLibrary.LiveUpload.delete_media_by_id(ctx.their_media.id, model: ctx.mine)

      assert Repo.get(Media, ctx.their_media.id)

      assert :ok =
               PhxMediaLibrary.LiveUpload.delete_media_by_id(ctx.my_media.id,
                 model: ctx.mine,
                 collection: :images
               )

      refute Repo.get(Media, ctx.my_media.id)
    end

    test "delete_media_by_id returns :ok with soft deletes", ctx do
      Application.put_env(:phx_media_library, :soft_deletes, true)
      on_exit(fn -> Application.delete_env(:phx_media_library, :soft_deletes) end)

      assert :ok = PhxMediaLibrary.LiveUpload.delete_media_by_id(ctx.my_media.id, model: ctx.mine)
    end
  end

  describe "mix phx_media_library.clean" do
    @describetag :db

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "keeps WebP-only media and removes records with no files" do
      png = create_temp_image(format: :png, width: 60, height: 60)

      {:ok, webp_only} =
        create_test_post()
        |> PhxMediaLibrary.add(png)
        |> PhxMediaLibrary.to_collection(:webp_only, disk: :local)

      refute File.exists?(PathGenerator.full_path(webp_only, nil))
      orphan = create_media(disk: "local")

      Mix.Tasks.PhxMediaLibrary.Clean.run(["--records-only", "--force", "--disk", "local"])

      assert Repo.get(Media, webp_only.id)
      refute Repo.get(Media, orphan.id)

      Media.delete_files(webp_only)
      File.rm(png)
    end
  end

  describe "mix phx_media_library.doctor --fix" do
    @describetag :db

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "deletes only media with no files left" do
      png = create_temp_image(format: :png, width: 60, height: 60)

      {:ok, webp_only} =
        create_test_post()
        |> PhxMediaLibrary.add(png)
        |> PhxMediaLibrary.to_collection(:webp_only, disk: :local)

      {:ok, missing_thumb} =
        create_test_post()
        |> PhxMediaLibrary.add(png)
        |> PhxMediaLibrary.to_collection(:images, disk: :local)

      missing_thumb = Repo.reload!(missing_thumb)
      assert Map.has_key?(missing_thumb.generated_conversions, "thumb")
      File.rm!(PathGenerator.full_path(missing_thumb, :thumb))

      no_files = create_media(disk: "local")

      # Parents are plain structs in these tests, so skip the orphan check.
      send(self(), {:mix_shell_input, :yes?, true})
      Mix.Tasks.PhxMediaLibrary.Doctor.run(["--fix", "--skip-orphans"])

      assert Repo.get(Media, webp_only.id)
      assert Repo.get(Media, missing_thumb.id)
      refute Repo.get(Media, no_files.id)

      Enum.each([webp_only, missing_thumb], &Media.delete_files/1)
      File.rm(png)
    end
  end

  describe "conversions" do
    @describetag :db

    test "run on storage without a local path by fetching a temporary copy" do
      media = create_media(disk: "memory", file_name: "photo.png", mime_type: "image/png")
      png = create_temp_image(format: :png, width: 60, height: 60)
      storage = Config.storage_adapter(:memory)
      :ok = StorageWrapper.put(storage, PathGenerator.relative_path(media, nil), File.read!(png))

      thumb = Conversion.new(:thumb, width: 20, height: 20)

      assert :ok = Conversions.process(media, [thumb])
      assert StorageWrapper.exists?(storage, PathGenerator.relative_path(media, :thumb))
      assert Repo.reload!(media).generated_conversions == %{"thumb" => true}

      Media.delete_files(Repo.reload!(media))
      File.rm(png)
    end

    test "return an error when the source is missing" do
      media = create_media(disk: "memory", collection_name: "images")
      thumb = Conversion.new(:thumb, width: 20, height: 20)

      assert {:error, :not_found} = Conversions.process(media, [thumb])
      assert {:error, :not_found} = Conversions.process_single(media, thumb)
    end

    test "report a failed conversion and keep the ones that succeeded" do
      previous = Application.get_env(:phx_media_library, :image_processor)

      Application.put_env(
        :phx_media_library,
        :image_processor,
        PhxMediaLibrary.FailingImageProcessor
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phx_media_library, :image_processor, previous),
          else: Application.delete_env(:phx_media_library, :image_processor)
      end)

      media = create_media(disk: "memory", file_name: "photo.png", mime_type: "image/png")
      png = create_temp_image(format: :png, width: 60, height: 60)
      storage = Config.storage_adapter(:memory)
      :ok = StorageWrapper.put(storage, PathGenerator.relative_path(media, nil), File.read!(png))

      conversions = [Conversion.new(:thumb, width: 20), Conversion.new(:broken, width: 20)]

      assert {:error, {:conversions_failed, [{:error, {:broken, {:error, :broken_on_purpose}}}]}} =
               Conversions.process(media, conversions)

      assert Repo.reload!(media).generated_conversions == %{"thumb" => true}

      Media.delete_files(Repo.reload!(media))
      File.rm(png)
    end

    test "a width-only conversion keeps the aspect ratio" do
      media = create_media(disk: "memory", file_name: "photo.png", mime_type: "image/png")
      png = create_temp_image(format: :png, width: 400, height: 200)
      storage = Config.storage_adapter(:memory)
      :ok = StorageWrapper.put(storage, PathGenerator.relative_path(media, nil), File.read!(png))

      assert :ok = Conversions.process(media, [Conversion.new(:preview, width: 100)])

      {:ok, bytes} = StorageWrapper.get(storage, PathGenerator.relative_path(media, :preview))
      {:ok, image} = Image.from_binary(bytes)
      assert {Image.width(image), Image.height(image)} == {100, 50}

      Media.delete_files(Repo.reload!(media))
      File.rm(png)
    end
  end
end
