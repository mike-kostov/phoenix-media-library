defmodule PhxMediaLibrary.CompactResponsiveTest do
  # Spec 02, C6: responsive_images stores widths, not paths; rows from
  # before 0.10 keep reading, and the doctor rewrites them.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{
    AsyncProcessor,
    Doctor,
    Health,
    Media,
    PathGenerator,
    Pipeline,
    ResponsiveImages
  }

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

    jpeg = create_temp_image(format: :jpg, width: 400, height: 300)
    on_exit(fn -> File.rm(jpeg) end)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(jpeg)
      |> PhxMediaLibrary.to_collection(:responsive_webp, disk: :local)

    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    %{media: TestRepo.reload!(media)}
  end

  # The same media, stored the way 0.9 stored it.
  defp as_legacy(media) do
    legacy =
      Map.new(media.responsive_images, fn
        {key, %{"widths" => _} = entry} ->
          source = if key == "original", do: nil, else: key

          {key,
           entry
           |> Map.drop(["widths", "width", "height", "formats"])
           |> Map.put("variants", ResponsiveImages.variants(media, source))}

        other ->
          other
      end)

    TestRepo.update!(Ecto.Changeset.change(media, responsive_images: legacy))
  end

  defp present(media), do: Enum.filter(Media.owned_paths(media), &File.exists?(full(media, &1)))

  defp full(media, relative) do
    root = Path.dirname(PathGenerator.full_path(media, nil))

    Path.join(
      root,
      Path.relative_to(relative, Path.dirname(PathGenerator.relative_path(media, nil)))
    )
  end

  test "new media stores widths, not paths", %{media: media} do
    assert %{"widths" => [160, 320], "width" => 400, "height" => 300, "formats" => ["webp"]} =
             media.responsive_images["original"]

    refute inspect(media.responsive_images) =~ "responsive/"

    assert [
             %{"width" => 160, "height" => 120, "path" => small},
             %{"width" => 320, "height" => 240},
             %{"width" => 400, "path" => full_size}
           ] = ResponsiveImages.variants(media, nil)

    assert small =~ ~r{/responsive/.+_160w\.webp$}
    assert full_size == media.custom_properties["webp"]

    assert Enum.all?(
             ResponsiveImages.variants(media, nil),
             &File.exists?(full(media, &1["path"]))
           )
  end

  test "both shapes give the same srcset, URLs, owned paths and health", %{media: media} do
    legacy = as_legacy(media)
    assert legacy.responsive_images["original"]["variants"]

    assert Media.srcset(legacy) == Media.srcset(media)

    assert PhxMediaLibrary.url(legacy, nil, width: 200) ==
             PhxMediaLibrary.url(media, nil, width: 200)

    assert Enum.sort(Media.owned_paths(legacy)) == Enum.sort(Media.owned_paths(media))
    assert Media.dimensions(legacy, :thumb) == Media.dimensions(media, :thumb)
    assert Health.check(legacy) == Health.check(media)
  end

  test "renaming moves the variants; their derived paths follow", %{media: media} do
    old = TestRepo.update!(Ecto.Changeset.change(media, file_name: "old-name.jpg"))

    for {from, to} <- Enum.zip(Media.owned_paths(media), Media.owned_paths(old)), from != to do
      File.mkdir_p!(Path.dirname(full(old, to)))
      File.rename!(full(media, from), full(old, to))
    end

    assert {:ok, renamed} = Pipeline.rename(old)
    assert renamed.responsive_images["original"]["widths"] == [160, 320]
    assert present(renamed) == Media.owned_paths(renamed)
  end

  test "doctor --rebuild responsive rewrites an old row", %{media: media} do
    legacy = as_legacy(media)

    assert {:ok, %{failed: 0}} = Doctor.repair(id: legacy.id, rebuild: [:responsive])

    rebuilt = TestRepo.reload!(legacy)
    assert %{"widths" => [160, 320]} = rebuilt.responsive_images["original"]
    refute Map.has_key?(rebuilt.responsive_images["original"], "variants")
    assert Media.srcset(rebuilt) == Media.srcset(media)
  end
end
