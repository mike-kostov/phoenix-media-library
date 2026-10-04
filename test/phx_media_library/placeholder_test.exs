defmodule PhxMediaLibrary.PlaceholderTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, Pipeline}

  @moduletag :db

  setup do
    # Apps start without the library's own responsive_images config.
    for key <- [:placeholder, :responsive_images] do
      previous = Application.fetch_env(:phx_media_library, key)
      Application.delete_env(:phx_media_library, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phx_media_library, key, value)
          :error -> Application.delete_env(:phx_media_library, key)
        end
      end)
    end

    photo = create_photo_with_profile()
    on_exit(fn -> File.rm(photo) end)
    %{photo: photo}
  end

  defp add(path, collection) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(path)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    media = TestRepo.get!(Media, media.id)
    on_exit(fn -> Media.delete_files(media) end)
    media
  end

  defp placeholder(media, key \\ "original"),
    do: get_in(media.responsive_images || %{}, [key, "placeholder"])

  defp webp_bytes(%{"data_uri" => "data:image/webp;base64," <> data}), do: Base.decode64!(data)

  test ":blur by default: a tiny WebP without metadata", %{photo: photo} do
    media = add(photo, :images)
    bytes = media |> placeholder() |> webp_bytes()

    assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = bytes
    assert byte_size(bytes) < 400
    refute bytes =~ "ICCP"
    refute bytes =~ "EXIF"
    assert placeholder(media)["width"] == 16
  end

  test ":color stores the average color", %{photo: _photo} do
    red = create_temp_image(color: "red", format: :png)
    on_exit(fn -> File.rm(red) end)

    assert placeholder(add(red, :color_placeholder)) == %{"color" => "#ff0000"}
  end

  test "false stores nothing", %{photo: photo} do
    assert placeholder(add(photo, :no_placeholder)) == nil
  end

  test "the global setting applies to collections without their own", %{photo: photo} do
    Application.put_env(:phx_media_library, :placeholder, :color)
    assert %{"color" => "#" <> _} = placeholder(add(photo, :images))
  end

  test "crop conversions get their own; same-shape ones use the original's", %{photo: photo} do
    media = add(photo, :images)

    # :thumb is a 150x150 crop; :preview (width 800) keeps the shape.
    assert %{"data_uri" => _} = placeholder(media, "thumb")
    assert placeholder(media, "preview") == nil
  end

  test "the step is skipped for files that aren't images" do
    media = create_media(%{mime_type: "application/pdf", file_name: "a.pdf", disk: "memory"})
    assert {:skip, :not_image} = Pipeline.placeholder(media)
  end

  test "responsive variants keep the placeholder", %{photo: photo} do
    media = add(photo, :responsive_plain)
    assert {:ok, media} = Pipeline.responsive(media)
    assert %{"data_uri" => _} = placeholder(media)
  end
end
