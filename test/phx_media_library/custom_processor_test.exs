defmodule PhxMediaLibrary.CustomProcessorTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, ResponsiveImages}

  @moduletag :db

  # FailingImageProcessor implements the behaviour as written: save/3 only.
  setup do
    previous = Application.fetch_env(:phx_media_library, :image_processor)

    Application.put_env(
      :phx_media_library,
      :image_processor,
      PhxMediaLibrary.FailingImageProcessor
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :image_processor, value)
        :error -> Application.delete_env(:phx_media_library, :image_processor)
      end
    end)

    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  test "responsive variants work with a processor that only has save/3", %{png: png} do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(:responsive_plain, disk: :local)

    media = TestRepo.get!(Media, media.id)
    on_exit(fn -> Media.delete_files(media) end)

    widths = for v <- ResponsiveImages.variants(media, nil), do: v["width"]
    assert 160 in widths and 320 in widths
  end
end
