defmodule PhxMediaLibrary.ResponsiveWebpTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Config, Media, StorageWrapper}

  @moduletag :image

  # WebP magic: "RIFF" <size::32> "WEBP".
  defp webp?(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: true
  defp webp?(_), do: false

  defp read_variant(media, path) do
    {:ok, content} = StorageWrapper.get(Config.storage_adapter(media.disk), path)
    content
  end

  describe "responsive generation via per-collection config" do
    test "WebP collection produces .webp variants that are actually WebP-encoded" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 400, height: 300)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:responsive_webp, disk: :local)

      variants = media.responsive_images["original"]["variants"]

      # widths [160, 320] both < 400 → 2 responsive variants + the full-size one
      resized = Enum.reject(variants, &(&1["width"] == 400))
      assert length(resized) == 2

      # every responsive variant path is .webp and holds real WebP bytes
      for %{"path" => path} <- resized do
        assert String.ends_with?(path, ".webp")
        assert webp?(read_variant(media, path))
      end

      # the full-size descriptor reuses the already-generated WebP sibling
      full = Enum.find(variants, &(&1["width"] == 400))
      assert full["path"] == media.custom_properties["webp"]
      assert String.ends_with?(full["path"], ".webp")

      # srcset is fully WebP with width descriptors
      srcset = Media.srcset(media)
      assert srcset =~ ".webp 160w"
      assert srcset =~ ".webp 320w"
      assert srcset =~ ".webp 400w"

      File.rm(jpg)
    end

    test "non-WebP responsive collection keeps the original extension" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 400, height: 300)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:responsive_plain, disk: :local)

      refute match?(%{"webp" => _}, media.custom_properties)

      variants = media.responsive_images["original"]["variants"]
      resized = Enum.reject(variants, &(&1["width"] == 400))
      assert length(resized) == 2

      for %{"path" => path} <- resized do
        assert String.ends_with?(path, ".jpg")
      end

      assert Media.srcset(media) =~ ".jpg 320w"

      File.rm(jpg)
    end

    test "collections without responsive config generate no variants" do
      post = create_test_post()
      jpg = create_temp_image(format: :jpg, width: 400, height: 300)

      assert {:ok, media} =
               post
               |> PhxMediaLibrary.add(jpg)
               |> PhxMediaLibrary.to_collection(:webp_photos, disk: :local)

      # webp: true but responsive not enabled → no srcset
      assert Media.srcset(media) in [nil, ""]

      File.rm(jpg)
    end
  end
end
