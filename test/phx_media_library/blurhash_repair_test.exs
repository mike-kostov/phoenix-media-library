defmodule PhxMediaLibrary.BlurhashRepairTest do
  # Spec 02, onboarding: existing and imported images get their BlurHash
  # when it is turned on later.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Conversions, Doctor, Health, Media, Model}

  @moduletag :db

  setup do
    previous = Application.fetch_env(:phx_media_library, :responsive_images)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :responsive_images, value)
        :error -> Application.delete_env(:phx_media_library, :responsive_images)
      end
    end)

    jpeg = create_temp_image(format: :jpg, width: 120, height: 80)
    on_exit(fn -> File.rm(jpeg) end)

    # Uploaded while BlurHash was off.
    Application.put_env(:phx_media_library, :responsive_images, blurhash: false)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(jpeg)
      |> PhxMediaLibrary.to_collection(:images, disk: :local)

    on_exit(fn -> Media.delete_files(media) end)
    %{media: TestRepo.reload!(media)}
  end

  defp blurhash_on,
    do: Application.put_env(:phx_media_library, :responsive_images, blurhash: true)

  test "the doctor reports a missing hash only when BlurHash is on", %{media: media} do
    refute :missing_blurhash in Health.check(media)

    blurhash_on()
    assert :missing_blurhash in Health.check(media)
  end

  test "--regenerate makes it", %{media: media} do
    blurhash_on()

    assert {:ok, %{done: 1, failed: 0}} =
             Doctor.repair(id: media.id, repairs: [:missing_blurhash])

    media = TestRepo.reload!(media)
    assert is_binary(Media.blurhash(media))
    refute :missing_blurhash in Health.check(media)
  end

  test "the background job makes a missing hash, as for an import", %{media: media} do
    blurhash_on()
    assert :ok = Conversions.process(media, Model.conversions(media, :images))
    assert is_binary(Media.blurhash(TestRepo.reload!(media)))
  end
end
