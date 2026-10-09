defmodule PhxMediaLibrary.DroppedOriginalTest do
  # Spec 02, B14: with keep_original: false the original is deleted after
  # upload and the served WebP is the only full copy. Missing derivatives
  # are reported and rebuilt from it.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{
    Config,
    Health,
    LocalSource,
    Media,
    PathGenerator,
    Pipeline,
    StorageWrapper
  }

  @moduletag :db

  setup do
    png = create_temp_image(format: :png, width: 400, height: 300)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(:dropped_original, disk: :local)

    on_exit(fn ->
      File.rm(png)
      Media.delete_files(media)
    end)

    refute File.exists?(PathGenerator.full_path(media, nil))
    %{media: media}
  end

  defp put(media, changes),
    do: media |> Ecto.Changeset.change(changes) |> Config.repo().update!()

  defp stored?(media, path), do: StorageWrapper.exists?(Config.storage_adapter(media.disk), path)

  test "missing widths are reported and made from the WebP", %{media: media} do
    media = put(media, responsive_images: %{})

    assert :missing_responsive in Health.check(media)
    assert {:ok, media} = Health.repair(media, :missing_responsive)

    assert [160, 320] = media.responsive_images["original"]["widths"]
    assert Enum.all?(PhxMediaLibrary.ResponsiveImages.paths(media, nil), &stored?(media, &1))
    refute :missing_responsive in Health.check(media)
  end

  test "a missing AVIF is reported and made from the WebP", %{media: media} do
    avif = media.custom_properties["avif"]
    StorageWrapper.delete(Config.storage_adapter(media.disk), avif)
    media = put(media, custom_properties: Map.delete(media.custom_properties, "avif"))

    assert :missing_avif in Health.check(media)
    assert {:ok, media} = Health.repair(media, :missing_avif)
    assert stored?(media, media.custom_properties["avif"])
  end

  test "missing dimensions are read from the WebP", %{media: media} do
    media = put(media, metadata: %{})

    assert :missing_metadata in Health.check(media)
    assert {:ok, media} = Health.repair(media, :missing_metadata)
    assert %{"width" => 400, "height" => 300} = media.metadata
  end

  test "without any file to read, re-reading dimensions fails instead of saving none",
       %{media: media} do
    StorageWrapper.delete(Config.storage_adapter(media.disk), media.custom_properties["webp"])

    assert {:error, :not_found} = Pipeline.metadata(put(media, metadata: %{}))
  end

  test "an old JPEG placeholder is reported and replaced", %{media: media} do
    jpeg = %{"data_uri" => "data:image/jpeg;base64,/9j/4AAQ", "width" => 32, "height" => 24}
    responsive = put_in(media.responsive_images, ["original", "placeholder"], jpeg)
    media = put(media, responsive_images: responsive)

    assert :outdated_placeholder in Health.check(media)
    assert {:ok, media} = Health.repair(media, :outdated_placeholder)

    assert "data:image/webp;base64," <> _ =
             media.responsive_images["original"]["placeholder"]["data_uri"]
  end

  test "the WebP is never re-encoded from itself", %{media: media} do
    read = fn ->
      LocalSource.with_stored_path(media, media.custom_properties["webp"], &File.read!/1)
    end

    before = read.()

    assert {:error, _} = Pipeline.webp(media)
    assert read.() == before
  end
end
