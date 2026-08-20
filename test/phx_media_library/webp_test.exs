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
               post |> PhxMediaLibrary.add(jpg) |> PhxMediaLibrary.to_collection(:images, disk: :local)

      assert String.ends_with?(media.file_name, ".jpg")
      refute match?(%{"webp" => _}, media.custom_properties)
      assert String.ends_with?(PhxMediaLibrary.url(media), ".jpg")

      File.rm(jpg)
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
