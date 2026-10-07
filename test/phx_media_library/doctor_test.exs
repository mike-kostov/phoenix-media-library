defmodule PhxMediaLibrary.DoctorTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Config, Doctor, Media, PathGenerator, StorageWrapper}
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  setup do
    png = create_temp_image(format: :png, width: 400, height: 300)
    on_exit(fn -> File.rm(png) end)
    %{png: png}
  end

  defp add(png, collection \\ :images) do
    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(png)
      |> PhxMediaLibrary.to_collection(collection, disk: :local)

    media = Repo.reload!(media)
    on_exit(fn -> if m = Repo.get(Media, media.id), do: Media.delete_files(m) end)
    media
  end

  defp drop_thumb(media),
    do:
      StorageWrapper.delete(
        Config.storage_adapter(:local),
        PathGenerator.relative_path(media, :thumb)
      )

  test "check/1 reports counts and examples, in batches", %{png: png} do
    media = for _ <- 1..3, do: add(png)
    Enum.each(media, &drop_thumb/1)

    assert {:ok, report} =
             Doctor.check(batch_size: 1, orphans: false, collection: "images", model: "posts")

    assert report.checked >= 3
    assert report.counts[:missing_conversions] >= 3
    assert [%{id: _, file_name: _} | _] = report.examples[:missing_conversions]
    assert report.errors == 0
  end

  test "check/1 with an ID checks one media item", %{png: png} do
    media = add(png)
    drop_thumb(media)

    assert {:ok, %{checked: 1, counts: %{missing_conversions: 1}}} = Doctor.check(id: media.id)
  end

  test "an invalid or unknown ID is an error, not an exception" do
    assert {:error, {:invalid_id, "42"}} = Doctor.check(id: "42")
    unknown = Ecto.UUID.generate()
    assert {:error, {:not_found, ^unknown}} = Doctor.check(id: unknown)
  end

  test "repair/1 runs the requested repairs and reports them", %{png: png} do
    media = add(png)
    drop_thumb(media)

    assert {:ok, %{done: 1, failed: 0}} =
             Doctor.repair(id: media.id, repairs: [:missing_conversions])

    assert StorageWrapper.exists?(
             Config.storage_adapter(:local),
             PathGenerator.relative_path(Repo.reload!(media), :thumb)
           )
  end

  test "repair/1 rebuilds what was asked", %{png: png} do
    media = add(png, :webp_photos)
    webp = media.custom_properties["webp"]
    StorageWrapper.put(Config.storage_adapter(:local), webp, "stale")

    assert {:ok, %{done: 1}} = Doctor.repair(id: media.id, rebuild: [:webp])
    {:ok, content} = StorageWrapper.get(Config.storage_adapter(:local), webp)
    refute content == "stale"
  end

  test "an unknown rebuild target is an error" do
    assert {:error, {:invalid_rebuild, :thumbnails}} = Doctor.repair(rebuild: [:thumbnails])
  end

  test "each run emits telemetry with the counts", %{png: png} do
    media = add(png)
    ref = :telemetry_test.attach_event_handlers(self(), [[:phx_media_library, :doctor, :check]])

    {:ok, _report} = Doctor.check(id: media.id)

    assert_received {[:phx_media_library, :doctor, :check], ^ref, %{checked: 1, errors: 0}, _}
  end

  test "works without Mix: the module never calls it" do
    source = File.read!("lib/phx_media_library/doctor.ex")
    refute source =~ "Mix."
  end
end
