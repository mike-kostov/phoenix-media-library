defmodule PhxMediaLibrary.DimensionLimitsTest do
  # Spec 02, F5: per-collection minimum and maximum image dimensions.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Collection, Media, ValidationError}

  @moduletag :db

  defp add(width, height) do
    image = create_temp_image(format: :png, width: width, height: height)
    on_exit(fn -> File.rm(image) end)

    result =
      create_test_post() |> PhxMediaLibrary.add(image) |> PhxMediaLibrary.to_collection(:sized)

    with {:ok, media} <- result, do: on_exit(fn -> Media.delete_files(media) end)
    result
  end

  test "images inside the limits are stored" do
    assert {:ok, _media} = add(200, 200)
    assert {:ok, _media} = add(100, 80)
    assert {:ok, _media} = add(500, 400)
  end

  test "each limit is its own error, naming the value and the limit" do
    assert {:error, {:image_too_narrow, 99, 100}} = add(99, 200)
    assert {:error, {:image_too_short, 79, 80}} = add(200, 79)
    assert {:error, {:image_too_wide, 501, 500}} = add(501, 200)
    assert {:error, {:image_too_tall, 401, 400}} = add(200, 401)
  end

  test "files that aren't images aren't measured" do
    txt = create_temp_file("notes", "notes.txt")
    on_exit(fn -> File.rm(txt) end)

    assert {:ok, media} =
             create_test_post()
             |> PhxMediaLibrary.add(txt)
             |> PhxMediaLibrary.to_collection(:sized)

    Media.delete_files(media)
  end

  test "collections without limits accept any size" do
    image = create_temp_image(format: :png, width: 10, height: 10)
    on_exit(fn -> File.rm(image) end)

    assert {:ok, media} =
             create_test_post()
             |> PhxMediaLibrary.add(image)
             |> PhxMediaLibrary.to_collection(:images)

    Media.delete_files(media)
  end

  test "an invalid limit is a configuration error" do
    assert_raise ArgumentError, ~r/min_width must be a positive integer/, fn ->
      Collection.new(:avatar, min_width: "200")
    end
  end

  test "ValidationError has a readable message" do
    error = ValidationError.exception(reason: :image_too_narrow, value: 99, constraint: 100)
    assert error.message == "Image is too narrow (99px, minimum width is 100px)"
  end
end
