defmodule PhxMediaLibrary.AvifTest do
  use PhxMediaLibrary.DataCase, async: false

  import ExUnit.CaptureLog
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, PathGenerator}

  @moduletag :db

  doctest PhxMediaLibrary.Avif

  setup do
    jpeg = create_temp_image(format: :jpg, width: 40, height: 30)
    on_exit(fn -> File.rm(jpeg) end)

    for key <- [:avif, :image_processor] do
      previous = Application.fetch_env(:phx_media_library, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end)
    end

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

  # Under the :local disk root from test_helper.
  defp avif_file(media), do: Path.join("priv/static/uploads", media.custom_properties["avif"])

  test "a collection with avif: true stores an AVIF beside the original", %{jpeg: jpeg} do
    media = add(jpeg, :avif_photos)

    assert media.custom_properties["avif"] ==
             Path.rootname(PathGenerator.relative_path(media, nil)) <> ".avif"

    assert <<_::binary-size(4), "ftypavif", _::binary>> = File.read!(avif_file(media))
  end

  test "the AVIF is owned: deleting the media removes it", %{jpeg: jpeg} do
    media = add(jpeg, :avif_photos)
    assert media.custom_properties["avif"] in Media.owned_paths(media)

    Media.delete_files(media)
    refute File.exists?(avif_file(media))
  end

  test "the AVIF has the served WebP's size", %{jpeg: jpeg} do
    media = add(jpeg, :avif_webp)

    {:ok, image} = Image.open(avif_file(media))
    assert {Image.width(image), Image.height(image)} == {20, 15}

    assert {media.custom_properties["webp_width"], media.custom_properties["webp_height"]} ==
             {20, 15}
  end

  test "conversions in an AVIF collection are AVIF files", %{jpeg: jpeg} do
    media = add(jpeg, :avif_webp)

    assert media.generated_conversions["thumb"] == "avif"
    assert PathGenerator.relative_path(media, :thumb) =~ ~r/_thumb\.avif$/
  end

  test "off by default", %{jpeg: jpeg} do
    Application.delete_env(:phx_media_library, :avif)
    media = add(jpeg, :images)

    refute Map.has_key?(media.custom_properties, "avif")
  end

  test "the global setting applies; a collection's overrides it", %{jpeg: jpeg} do
    Application.put_env(:phx_media_library, :avif, true)

    assert Map.has_key?(add(jpeg, :images).custom_properties, "avif")
    refute Map.has_key?(add(jpeg, :no_avif).custom_properties, "avif")
  end

  test "without AVIF support, uploads succeed and it is logged once", %{jpeg: jpeg} do
    Application.put_env(
      :phx_media_library,
      :image_processor,
      PhxMediaLibrary.NoAvifImageProcessor
    )

    :persistent_term.erase({PhxMediaLibrary.Avif, :unsupported_logged})

    log =
      capture_log(fn ->
        refute Map.has_key?(add(jpeg, :avif_photos).custom_properties, "avif")
        refute Map.has_key?(add(jpeg, :avif_photos).custom_properties, "avif")
      end)

    assert length(String.split(log, "AVIF is enabled")) - 1 == 1
  end
end
