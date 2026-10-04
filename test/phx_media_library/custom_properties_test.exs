defmodule PhxMediaLibrary.CustomPropertiesTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.Media
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  setup do
    %{media: create_media(custom_properties: %{"photographer" => "Ana", "webp" => "a.webp"})}
  end

  test "update_alt_text/2 sets the alt text components use", %{media: media} do
    assert {:ok, media} = PhxMediaLibrary.update_alt_text(media, "Red summer dress")
    assert Media.alt_text(Repo.reload!(media)) == "Red summer dress"
  end

  test "nil removes the alt text, falling back to the uploaded name", %{media: media} do
    {:ok, media} = PhxMediaLibrary.update_alt_text(media, "Red summer dress")
    {:ok, media} = PhxMediaLibrary.update_alt_text(media, nil)

    refute Map.has_key?(media.custom_properties, "alt")
    assert Media.alt_text(media) == "test file"
  end

  test "update_custom_properties/2 merges, keeps other keys, accepts atom keys", %{media: media} do
    assert {:ok, media} = PhxMediaLibrary.update_custom_properties(media, %{caption: "New in"})

    assert %{"caption" => "New in", "photographer" => "Ana", "webp" => "a.webp"} =
             Repo.reload!(media).custom_properties
  end

  test "keys the library maintains are refused", %{media: media} do
    assert {:error, {:reserved_properties, ["webp"]}} =
             PhxMediaLibrary.update_custom_properties(media, %{"webp" => "evil.webp"})

    assert Repo.reload!(media).custom_properties["webp"] == "a.webp"
  end
end
