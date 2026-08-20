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

    test "keep_original: false — original replaced by the WebP" do
      post = create_test_post()
      png = create_temp_image(format: :png, width: 60, height: 60)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(png)
               |> PhxMediaLibrary.to_collection(:webp_only, disk: :local)

      assert String.ends_with?(media.file_name, ".webp")
      assert media.mime_type == "image/webp"
      assert String.ends_with?(PhxMediaLibrary.url(media), ".webp")
      # checksum reflects the served (WebP) bytes
      assert is_binary(media.checksum)

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
end
