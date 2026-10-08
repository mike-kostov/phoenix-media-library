defmodule PhxMediaLibrary.AvifVariantsTest do
  use PhxMediaLibrary.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, ResponsiveImages, ViewHelpers}

  @moduletag :db

  setup do
    jpeg = create_temp_image(format: :jpg, width: 400, height: 300)
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

  defp variant_paths(media),
    do: for(v <- ResponsiveImages.variants(media, nil), do: v["path"])

  test "with AVIF and WebP on, every variant is AVIF and no WebP variant exists", %{jpeg: jpeg} do
    media = add(jpeg, :avif_responsive)
    paths = variant_paths(media)

    assert length(paths) == 3
    assert Enum.all?(paths, &String.ends_with?(&1, ".avif"))
    assert List.last(paths) == media.custom_properties["avif"]

    # No size of the original exists twice (conversions' WebP variants live
    # in the same folder).
    responsive_dir = Path.join(["priv/static/uploads", Path.dirname(hd(paths))])
    base = Path.rootname(media.file_name)

    refute responsive_dir
           |> File.ls!()
           |> Enum.any?(&(&1 =~ ~r/^#{base}_\d+w\.webp$/))
  end

  test "<.picture> offers AVIF, then WebP, then the img", %{jpeg: jpeg} do
    media = add(jpeg, :avif_responsive)
    html = render_component(&ViewHelpers.picture/1, media: media)

    assert [_, avif, webp, img] = String.split(html, ~r/<source|<img/)
    assert avif =~ ~s(type="image/avif")
    assert avif =~ "_160w.avif 160w"
    assert webp =~ ~s(type="image/webp")
    assert webp =~ media.custom_properties["webp"]
    assert img =~ ~s(src=")
    refute img =~ "srcset"
  end

  test "<.responsive_img> becomes a <picture> when the media has an AVIF", %{jpeg: jpeg} do
    html = render_component(&ViewHelpers.responsive_img/1, media: add(jpeg, :avif_responsive))

    # display: contents: the page's layout sees only the <img>.
    assert html =~ ~s(<picture style="display: contents">)
    assert html =~ ~s(type="image/avif")
    assert html =~ ~s(loading="lazy")
  end

  test "<.responsive_img> stays a plain <img> without AVIF", %{jpeg: jpeg} do
    html = render_component(&ViewHelpers.responsive_img/1, media: add(jpeg, :responsive_webp))

    refute html =~ "<picture>"
    assert html =~ "srcset="
  end

  test "no conversion variant or plain URL is AVIF", %{jpeg: jpeg} do
    media = add(jpeg, :avif_responsive)

    # Conversions are AVIF and WebP (spec 02, F1); their URLs are the WebP.
    assert media.generated_conversions |> Map.values() |> Enum.all?(&(&1 == ["avif", "webp"]))

    for {key, _entry} <- media.responsive_images,
        key != "original",
        variant <- ResponsiveImages.variants(media, key),
        do: refute(variant["path"] =~ ".avif", "#{key} has an AVIF variant")

    for conversion <- [nil, :thumb, :preview],
        do: refute(PhxMediaLibrary.url(media, conversion) =~ ".avif")

    html = render_component(&ViewHelpers.responsive_img/1, media: media, conversion: :preview)
    refute html =~ ".avif"
  end
end
