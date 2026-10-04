defmodule PhxMediaLibrary.ConversionExtensionTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Conversion, Conversions, Media, PathGenerator, Pipeline}

  @moduletag :db

  @small_webp %Conversion{name: :small_webp, width: 20, format: :webp}

  setup do
    jpeg = create_temp_image(format: :jpg, width: 40, height: 40)
    on_exit(fn -> File.rm(jpeg) end)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(jpeg)
      |> PhxMediaLibrary.to_collection(:images, disk: :local)

    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    %{media: media}
  end

  defp convert(media, conversion) do
    :ok = Conversions.process_single(media, conversion)
    TestRepo.get!(Media, media.id)
  end

  test "a conversion with format: :webp is stored as .webp, with WebP bytes", %{media: media} do
    media = convert(media, @small_webp)

    assert media.generated_conversions["small_webp"] == "webp"
    assert PathGenerator.relative_path(media, :small_webp) =~ ~r/_small_webp\.webp$/
    assert PhxMediaLibrary.url(media, :small_webp) =~ ~r/_small_webp\.webp$/

    assert <<"RIFF", _size::binary-size(4), "WEBP", _::binary>> =
             File.read!(PathGenerator.full_path(media, :small_webp))

    assert Media.has_conversion?(media, :small_webp) == true
  end

  test "a conversion without a format is WebP, in any collection", %{media: media} do
    media = convert(media, %Conversion{name: :small, width: 20})

    assert media.generated_conversions["small"] == "webp"
    assert PathGenerator.relative_path(media, :small) =~ ~r/_small\.webp$/
  end

  test "format: :original keeps the original's format", %{media: media} do
    media = convert(media, %Conversion{name: :small, width: 20, format: :original})

    assert media.generated_conversions["small"] == true
    assert PathGenerator.relative_path(media, :small) =~ ~r/_small\.jpg$/
  end

  test "media recorded before the fix keeps resolving to the original's extension" do
    media = %Media{
      uuid: Ecto.UUID.generate(),
      collection_name: "images",
      file_name: "photo.jpg",
      disk: "local",
      mediable_type: "posts",
      mediable_id: "42",
      generated_conversions: %{"thumb" => true}
    }

    assert PathGenerator.relative_path(media, :thumb) =~ ~r/photo_thumb\.jpg$/
  end

  test "deleting removes the .webp conversion", %{media: media} do
    media = convert(media, @small_webp)
    path = PathGenerator.full_path(media, :small_webp)
    assert File.exists?(path)

    Media.delete_files(media)
    refute File.exists?(path)
  end

  test "renaming moves the .webp conversion", %{media: media} do
    media = convert(media, @small_webp)

    # Make it look stored under an old name, so rename has work to do.
    old = TestRepo.update!(Ecto.Changeset.change(media, file_name: "old-name.jpg"))

    for conversion <- [nil, :small_webp] do
      File.rename!(
        PathGenerator.full_path(media, conversion),
        PathGenerator.full_path(old, conversion)
      )
    end

    assert {:ok, renamed} = Pipeline.rename(old)
    assert PathGenerator.full_path(renamed, :small_webp) =~ ~r/_small_webp\.webp$/
    assert File.exists?(PathGenerator.full_path(renamed, :small_webp))
    refute File.exists?(PathGenerator.full_path(old, :small_webp))
  end

  test "clean and the doctor count the .webp conversion as owned", %{media: media} do
    media = convert(media, @small_webp)
    webp_path = PathGenerator.relative_path(media, :small_webp)

    assert webp_path =~ ~r/\.webp$/
    assert webp_path in Media.owned_paths(media)
  end

  describe "in a WebP collection (ADR-024)" do
    setup do
      jpeg = create_temp_image(format: :jpg, width: 40, height: 40)
      on_exit(fn -> File.rm(jpeg) end)

      {:ok, media} =
        create_test_post()
        |> PhxMediaLibrary.add(jpeg)
        |> PhxMediaLibrary.to_collection(:webp_photos, disk: :local)

      media = TestRepo.get!(Media, media.id)
      on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
      %{webp_media: media}
    end

    test "conversions without a format are WebP files", %{webp_media: media} do
      for name <- [:thumb, :preview] do
        assert media.generated_conversions[to_string(name)] == "webp"

        assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> =
                 File.read!(PathGenerator.full_path(media, name))
      end
    end

    test "an explicit format still wins", %{webp_media: media} do
      media = convert(media, %Conversion{name: :small_png, width: 20, format: :png})

      assert media.generated_conversions["small_png"] == "png"

      assert <<0x89, "PNG", _::binary>> =
               File.read!(PathGenerator.full_path(media, :small_png))
    end

    test "rebuilding converts a conversion stored before, and removes the old file",
         %{webp_media: media} do
      # As stored before 0.9: a JPEG thumb recorded as `true`.
      old =
        TestRepo.update!(Ecto.Changeset.change(media, generated_conversions: %{"thumb" => true}))

      old_path = PathGenerator.full_path(old, :thumb)
      File.write!(old_path, File.read!(PathGenerator.full_path(old, nil)))

      assert :ok = Pipeline.conversions(old, only: [:thumb])

      rebuilt = TestRepo.get!(Media, media.id)
      assert rebuilt.generated_conversions["thumb"] == "webp"
      assert File.exists?(PathGenerator.full_path(rebuilt, :thumb))
      refute File.exists?(old_path)
    end
  end
end
