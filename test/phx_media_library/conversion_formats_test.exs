defmodule PhxMediaLibrary.ConversionFormatsTest do
  # Spec 02, F1: each conversion in every listed format; the last one is
  # what plain URLs serve.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Conversion, Conversions, Doctor, Media, PathGenerator, Pipeline}

  @moduletag :db

  setup do
    jpeg = create_temp_image(format: :jpg, width: 40, height: 40)
    on_exit(fn -> File.rm(jpeg) end)
    %{jpeg: jpeg}
  end

  defp add(jpeg, collection) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(jpeg)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    on_exit(fn -> Media.delete_files(TestRepo.get(Media, media.id) || media) end)
    TestRepo.reload!(media)
  end

  defp convert(media, conversion) do
    :ok = Conversions.process_single(media, conversion)
    TestRepo.get!(Media, media.id)
  end

  defp card(formats), do: Conversion.new(:card, width: 20, formats: formats)

  defp files(media, name),
    do: Enum.map(PathGenerator.conversion_paths(media, name), &full_path(media, &1))

  defp full_path(media, relative),
    do: Path.join(Path.dirname(PathGenerator.full_path(media, nil)), Path.basename(relative))

  test "formats: [:avif, :webp] stores both; url/2 is the WebP", %{jpeg: jpeg} do
    media = jpeg |> add(:images) |> convert(card([:avif, webp: [quality: 70]]))

    assert media.generated_conversions["card"] == ["avif", "webp"]
    assert [avif, webp] = files(media, :card)
    assert avif =~ ~r/_card\.avif$/
    assert <<_::binary-size(4), "ftypavif", _::binary>> = File.read!(avif)
    assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = File.read!(webp)

    assert PhxMediaLibrary.url(media, :card) =~ ~r/_card\.webp$/
    assert PathGenerator.relative_path(media, :card) =~ ~r/_card\.webp$/
  end

  test "deleting removes every format", %{jpeg: jpeg} do
    media = jpeg |> add(:images) |> convert(card([:avif, :webp]))
    paths = files(media, :card)
    assert Enum.all?(paths, &File.exists?/1)

    Media.delete_files(media)
    refute Enum.any?(paths, &File.exists?/1)
  end

  test "renaming moves every format", %{jpeg: jpeg} do
    media = jpeg |> add(:images) |> convert(card([:avif, :webp]))
    old = TestRepo.update!(Ecto.Changeset.change(media, file_name: "old-name.jpg"))

    for {from, to} <- [
          {PathGenerator.full_path(media, nil), PathGenerator.full_path(old, nil)}
          | Enum.zip(files(media, :card), files(old, :card))
        ],
        do: File.rename!(from, to)

    assert {:ok, renamed} = Pipeline.rename(old)
    assert [_, _] = files(renamed, :card)
    assert Enum.all?(files(renamed, :card), &File.exists?/1)
    refute Enum.any?(files(old, :card), &File.exists?/1)
  end

  test "rebuilt in fewer formats, the dropped ones are removed", %{jpeg: jpeg} do
    media = jpeg |> add(:images) |> convert(card([:avif, :webp]))
    [avif, _webp] = files(media, :card)

    media = convert(media, card([:webp]))

    assert media.generated_conversions["card"] == "webp"
    refute File.exists?(avif)
  end

  test "the doctor finds and remakes a missing format", %{jpeg: jpeg} do
    media = add(jpeg, :avif_webp)
    [avif, _webp] = files(media, :thumb)
    File.rm!(avif)

    assert {:ok, %{counts: %{missing_conversions: 1}}} = Doctor.check(id: media.id)
    assert {:ok, %{done: 1}} = Doctor.repair(id: media.id, repairs: [:missing_conversions])
    assert File.exists?(avif)
  end

  test "without AVIF support, the other formats are made", %{jpeg: jpeg} do
    previous = Application.fetch_env(:phx_media_library, :image_processor)

    Application.put_env(
      :phx_media_library,
      :image_processor,
      PhxMediaLibrary.NoAvifImageProcessor
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :image_processor, value)
        :error -> Application.delete_env(:phx_media_library, :image_processor)
      end
    end)

    media = jpeg |> add(:images) |> convert(card([:avif, :webp]))

    assert media.generated_conversions["card"] == "webp"
  end

  # Mike, 2026-10-08: formats: alone makes the original's copies too, so its
  # variants come in every listed format.
  test "formats: [:avif, :webp] alone: copies, variants and conversions in both", %{jpeg: jpeg} do
    media = add(jpeg, :listed_formats)

    assert is_binary(media.custom_properties["avif"])
    assert is_binary(media.custom_properties["webp"])
    assert PhxMediaLibrary.ResponsiveImages.formats(media, nil) == ["avif", "webp"]
    assert media.generated_conversions["thumb"] == ["avif", "webp"]
    assert PhxMediaLibrary.url(media) =~ ~r/\.webp$/
  end

  test "media recorded in 0.9 keeps resolving" do
    media = %Media{
      uuid: Ecto.UUID.generate(),
      collection_name: "images",
      file_name: "photo.jpg",
      mediable_type: "posts",
      mediable_id: "42",
      generated_conversions: %{"thumb" => "webp", "small" => true}
    }

    assert [webp] = PathGenerator.conversion_paths(media, :thumb)
    assert webp =~ ~r/photo_thumb\.webp$/
    assert [jpg] = PathGenerator.conversion_paths(media, :small)
    assert jpg =~ ~r/photo_small\.jpg$/
  end
end
