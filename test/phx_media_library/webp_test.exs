defmodule PhxMediaLibrary.WebpTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  @moduletag :image

  describe "webp conversion on add" do
    test "keep_original: true — original kept, WebP generated and served" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 60, height: 60)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:webp_photos, disk: :local)

      # original is retained as the primary file
      assert String.ends_with?(media.file_name, ".jpg")
      assert media.mime_type == "image/jpeg"

      # a WebP sibling was recorded and is what get_url serves
      assert %{"webp" => webp_path} = media.custom_properties
      assert String.ends_with?(webp_path, ".webp")
      assert String.ends_with?(PhxMediaLibrary.url(media), ".webp")

      File.rm(jpg)
    end

    test "keep_original: false — source removed after conversions, WebP served" do
      post = create_test_post()
      png = create_temp_image(format: :png, width: 60, height: 60)

      # :webp_only inherits the thumb/preview conversions — this exercises the
      # ordering: conversions (from the source) must run before the source is
      # deleted. It must not raise.
      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(png)
               |> PhxMediaLibrary.to_collection(:webp_only, disk: :local)

      # WebP is served
      assert %{"webp" => _} = media.custom_properties
      assert String.ends_with?(PhxMediaLibrary.url(media), ".webp")

      # the source file was deleted — but only AFTER conversions produced their
      # thumbnails from it (proving deletion is the last step, not before).
      refute File.exists?(PhxMediaLibrary.PathGenerator.full_path(media, nil))
      assert map_size(PhxMediaLibrary.Config.repo().reload!(media).generated_conversions) > 0

      File.rm(png)
    end

    test "non-WebP collection is untouched" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 60, height: 60)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:images, disk: :local)

      assert String.ends_with?(media.file_name, ".jpg")
      refute match?(%{"webp" => _}, media.custom_properties)
      assert String.ends_with?(PhxMediaLibrary.url(media), ".jpg")

      File.rm(jpg)
    end
  end

  describe "max_dimension" do
    test "oversized source is fitted into the cap, aspect kept, dims recorded" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 300, height: 150)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:webp_capped, disk: :local)

      assert %{"webp" => webp_path, "webp_width" => 100, "webp_height" => 50} =
               media.custom_properties

      {:ok, content} =
        PhxMediaLibrary.StorageWrapper.get(
          PhxMediaLibrary.Config.storage_adapter(:local),
          webp_path
        )

      tmp = Path.join(System.tmp_dir!(), "capped-#{System.unique_integer([:positive])}.webp")
      File.write!(tmp, content)
      {:ok, image} = Image.open(tmp)
      assert {Image.width(image), Image.height(image)} == {100, 50}

      File.rm(tmp)
      File.rm(jpg)
    end

    test "smaller source is not upscaled" do
      post = create_test_post()
      png = create_temp_image(format: :png, width: 60, height: 40)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(png)
               |> PhxMediaLibrary.to_collection(:webp_capped, disk: :local)

      assert %{"webp_width" => 60, "webp_height" => 40} = media.custom_properties
      File.rm(png)
    end

    test "uncapped collection records no dimensions" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 60, height: 60)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:webp_photos, disk: :local)

      refute Map.has_key?(media.custom_properties, "webp_width")
      File.rm(jpg)
    end

    test "responsive variants above the cap are skipped and the largest descriptor is the capped WebP" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 400, height: 200)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:webp_capped, disk: :local)

      widths =
        media.responsive_images["original"]["variants"] |> Enum.map(& &1["width"]) |> Enum.sort()

      # 50 and 80 are below the 100px served width; 200 would upscale; 100 is the WebP itself
      assert widths == [50, 80, 100]

      largest = Enum.find(media.responsive_images["original"]["variants"], &(&1["width"] == 100))
      assert largest["path"] == media.custom_properties["webp"]
      assert largest["height"] == 50

      File.rm(jpg)
    end

    test "fit_dimensions/2" do
      alias PhxMediaLibrary.Webp
      assert Webp.fit_dimensions({3000, 2000}, 1200) == {1200, 800}
      assert Webp.fit_dimensions({2000, 3000}, 1200) == {800, 1200}
      assert Webp.fit_dimensions({600, 400}, 1200) == {600, 400}
      assert Webp.fit_dimensions({600, 400}, nil) == {600, 400}
    end
  end

  describe "url width: option" do
    test "picks the smallest variant at least as wide, else the widest, else the served file" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 400, height: 200)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:webp_capped, disk: :local)

      assert String.ends_with?(PhxMediaLibrary.Media.url(media, nil, width: 50), "_50w.webp")
      assert String.ends_with?(PhxMediaLibrary.Media.url(media, nil, width: 51), "_80w.webp")
      # wider than any variant → the capped WebP itself
      assert PhxMediaLibrary.Media.url(media, nil, width: 999) == PhxMediaLibrary.Media.url(media)

      assert PhxMediaLibrary.get_first_media_url(post, :webp_capped, width: 50) ==
               PhxMediaLibrary.Media.url(media, nil, width: 50)

      File.rm(jpg)
    end

    test "media without variants falls back to the regular url" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 60, height: 60)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:webp_photos, disk: :local)

      assert PhxMediaLibrary.Media.url(media, nil, width: 320) == PhxMediaLibrary.Media.url(media)
      File.rm(jpg)
    end

    test "legacy list-shaped responsive data still resolves" do
      media = %PhxMediaLibrary.Media{
        disk: "local",
        file_name: "a.jpg",
        uuid: Ecto.UUID.generate(),
        mediable_type: "posts",
        mediable_id: "1",
        collection_name: "images",
        responsive_images: %{"original" => [%{"width" => 100, "path" => "x/a_100w.jpg"}]}
      }

      assert String.ends_with?(PhxMediaLibrary.Media.url(media, nil, width: 80), "x/a_100w.jpg")
    end
  end

  describe "conversions without a local source" do
    @describetag :db

    test "skip gracefully instead of crashing (memory / S3 disk)" do
      # memory disk → PathGenerator.full_path/2 is nil; must not raise on Image.open(nil)
      media = create_media(disk: "memory", collection_name: "images")
      conv = PhxMediaLibrary.Conversion.new(:thumb, width: 50, height: 50)

      assert PhxMediaLibrary.Conversions.process(media, [conv]) == :ok
      assert PhxMediaLibrary.Conversions.process_single(media, conv) == :ok
    end
  end
end
