defmodule PhxMediaLibrary.BlurhashTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Blurhash, Media}
  alias PhxMediaLibrary.ResponsiveImages.WidthCalculator

  @moduletag :db

  doctest WidthCalculator

  @base83 ~r/^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]+$/

  setup do
    jpeg = create_temp_image(format: :jpg, width: 120, height: 80)
    on_exit(fn -> File.rm(jpeg) end)
    %{jpeg: jpeg}
  end

  test "a hash's length follows its components; same image, same hash", %{jpeg: jpeg} do
    assert {:ok, hash} = Blurhash.generate(jpeg)
    assert String.length(hash) == 6 + 2 * (4 * 3 - 1)
    assert hash =~ @base83
    assert {:ok, ^hash} = Blurhash.generate(jpeg)

    assert {:ok, wide} = Blurhash.generate(jpeg, components_x: 5, components_y: 4)
    assert String.length(wide) == 6 + 2 * (5 * 4 - 1)

    # Components are clamped to 1..9.
    assert {:ok, clamped} = Blurhash.generate(jpeg, components_x: 20, components_y: 0)
    # 9 by 1 components: 8 AC pairs.
    assert String.length(clamped) == 6 + 2 * 8
  end

  @alphabet "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"

  defp decode83(chars) do
    chars
    |> String.graphemes()
    |> Enum.reduce(0, fn c, acc -> acc * 83 + (:binary.match(@alphabet, c) |> elem(0)) end)
  end

  test "the DC component is the image's average colour" do
    # sRGB 128, 64, 191 as 0.0–1.0.
    pixels = List.duplicate({128 / 255, 64 / 255, 191 / 255}, 16 * 16)
    hash = Blurhash.encode(pixels, 16, 16, 4, 3)

    assert String.length(hash) == 28
    <<"L", _max_ac::binary-1, dc::binary-4, _ac::binary>> = hash
    value = decode83(dc)

    assert {Bitwise.bsr(value, 16), Bitwise.band(Bitwise.bsr(value, 8), 255),
            Bitwise.band(value, 255)} == {128, 64, 191}
  end

  test "an unreadable source is an error, not an exception" do
    assert {:error, _} = Blurhash.generate("/no/such/file.jpg")
  end

  test "uploads store a hash when blurhash is on", %{jpeg: jpeg} do
    previous = Application.fetch_env(:phx_media_library, :responsive_images)
    Application.put_env(:phx_media_library, :responsive_images, blurhash: true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :responsive_images, value)
        :error -> Application.delete_env(:phx_media_library, :responsive_images)
      end
    end)

    {:ok, media} =
      create_test_post() |> PhxMediaLibrary.add(jpeg) |> PhxMediaLibrary.to_collection(:images)

    on_exit(fn -> Media.delete_files(media) end)

    assert media.responsive_images["blurhash"] =~ @base83
  end
end
