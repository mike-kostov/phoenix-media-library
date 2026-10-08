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

  defp variant_paths(media, format),
    do: for(v <- ResponsiveImages.variants(media, nil, format), do: v["path"])

  # avif: true is formats: [:avif, :webp] (spec 02, F1; ADR-024 amendment 2).
  test "with AVIF and WebP on, each size comes in both, each list in one format", %{jpeg: jpeg} do
    media = add(jpeg, :avif_responsive)
    assert ResponsiveImages.formats(media, nil) == ["avif", "webp"]

    avif = variant_paths(media, "avif")
    webp = variant_paths(media, "webp")

    assert length(avif) == 3 and Enum.all?(avif, &String.ends_with?(&1, ".avif"))
    assert length(webp) == 3 and Enum.all?(webp, &String.ends_with?(&1, ".webp"))
    assert List.last(avif) == media.custom_properties["avif"]
    assert List.last(webp) == media.custom_properties["webp"]
    assert Enum.all?(avif ++ webp, &File.exists?(Path.join("priv/static/uploads", &1)))
  end

  test "<.picture> offers AVIF, then the WebP img, each with its srcset", %{jpeg: jpeg} do
    media = add(jpeg, :avif_responsive)
    html = render_component(&ViewHelpers.picture/1, media: media)

    assert [_, avif, img] = String.split(html, ~r/<source|<img/)
    assert avif =~ ~s(type="image/avif")
    assert avif =~ "_160w.avif 160w"
    refute avif =~ ".webp"
    assert img =~ ~s(src="/uploads/#{media.custom_properties["webp"]}")
    assert img =~ "_160w.webp 160w"
    refute img =~ ".avif"
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

  test "no plain URL or <img> is AVIF; conversions offer it as a source", %{jpeg: jpeg} do
    media = add(jpeg, :avif_responsive)

    # Conversions are AVIF and WebP (spec 02, F1); their URLs are the WebP.
    assert media.generated_conversions |> Map.values() |> Enum.all?(&(&1 == ["avif", "webp"]))

    for conversion <- [nil, :thumb, :preview],
        do: refute(PhxMediaLibrary.url(media, conversion) =~ ".avif")

    html = render_component(&ViewHelpers.responsive_img/1, media: media, conversion: :preview)
    assert [_, avif, img] = String.split(html, ~r/<source|<img/)
    assert avif =~ ~s(type="image/avif")
    refute avif =~ ".webp"
    assert img =~ ~r/src="[^"]+_preview\.webp"/
    refute img =~ ".avif"
  end

  test "a 0.9 AVIF row still renders: AVIF source, WebP img", %{jpeg: jpeg} do
    media = add(jpeg, :avif_responsive)
    avif = ResponsiveImages.variants(media, nil, "avif")
    legacy = put_in(media.responsive_images["original"], %{"variants" => avif})

    html = render_component(&ViewHelpers.responsive_img/1, media: legacy)
    assert [_, source, img] = String.split(html, ~r/<source|<img/)
    assert source =~ "_160w.avif 160w"
    assert img =~ ~s(src="/uploads/#{media.custom_properties["webp"]}")
    refute img =~ "srcset"
  end
end
