defmodule PhxMediaLibrary.SharedVariantsTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.Media

  @moduletag :db

  # :preview is 800px wide, the original's shape; :thumb (150x150) and
  # :banner (1200x400) are crops.
  setup do
    jpeg = create_temp_image(format: :jpg, width: 1600, height: 1200)
    on_exit(fn -> File.rm(jpeg) end)
    %{jpeg: jpeg}
  end

  defp add(jpeg, collection) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(jpeg)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    media = TestRepo.get!(Media, media.id)
    on_exit(fn -> Media.delete_files(media) end)
    media
  end

  defp responsive_files(media) do
    dir =
      Path.join([
        "priv/static/uploads",
        Path.dirname(PhxMediaLibrary.PathGenerator.relative_path(media, nil)),
        "responsive"
      ])

    File.ls!(dir)
  end

  test "a same-shape conversion gets no variants of its own", %{jpeg: jpeg} do
    media = add(jpeg, :responsive_plain)
    files = responsive_files(media)

    assert Enum.any?(files, &(&1 =~ ~r/_160w\./))
    refute Enum.any?(files, &(&1 =~ ~r/_preview_\d+w\./))
  end

  test "its srcset uses the original's variants up to its width, plus itself", %{jpeg: jpeg} do
    media = add(jpeg, :responsive_plain)
    srcset = PhxMediaLibrary.srcset(media, :preview)

    assert [w160, w320, w800] = String.split(srcset, ", ")
    # The original's variants, not the conversion's.
    assert w160 =~ ~r/_responsive-plain_[^_]+_160w\.jpg 160w$/
    assert w320 =~ ~r/_responsive-plain_[^_]+_320w\.jpg 320w$/
    assert w800 =~ ~r/_preview\.jpg 800w$/
    assert Media.dimensions(media, :preview) == {800, 600}
  end

  test "the width: URL option picks from the same list", %{jpeg: jpeg} do
    media = add(jpeg, :responsive_plain)

    assert PhxMediaLibrary.url(media, :preview, width: 300) =~
             ~r/_responsive-plain_[^_]+_320w\.jpg$/

    assert PhxMediaLibrary.url(media, :preview, width: 500) =~ ~r/_preview\.jpg$/
  end

  test "crops keep their own variants", %{jpeg: jpeg} do
    media = add(jpeg, :images)
    files = responsive_files(media)

    assert Enum.any?(files, &(&1 =~ ~r/_banner_\d+w\./))
    refute media.responsive_images["banner"]["reuses"]
  end
end
